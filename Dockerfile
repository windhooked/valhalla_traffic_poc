FROM ubuntu:20.04
ENV DISTRIB_ID=Ubuntu
ENV DISTRIB_RELEASE=20.04
ENV DISTRIB_CODENAME=focal
ENV DISTRIB_DESCRIPTION="Ubuntu 20.04.2 LTS"

RUN apt-get update
RUN apt-get install -y software-properties-common
RUN add-apt-repository -y ppa:valhalla-core/valhalla
RUN apt-get update

# Install build dependencies
RUN apt-get install -y cmake make libtool pkg-config g++ gcc curl unzip jq lcov protobuf-compiler vim-common locales libboost-all-dev libcurl4-openssl-dev zlib1g-dev liblz4-dev libprime-server-dev libprotobuf-dev prime-server-bin
RUN apt-get install -y libgeos-dev libgeos++-dev libluajit-5.1-dev libspatialite-dev libsqlite3-dev wget sqlite3 spatialite-bin
RUN apt-get install -y python-is-python3

RUN if [[ $(python -c "print(int($DISTRIB_RELEASE > 15))") > 0 ]]; then sudo apt-get install -y libsqlite3-mod-spatialite; fi
RUN apt-get install -y libsqlite3-mod-spatialite python-all-dev git

RUN git clone --recurse-submodules https://github.com/valhalla/valhalla.git

# Demo utility that uses existing functions from Valhalla code
COPY valhalla_code_overwrites/src/mjolnir/valhalla_traffic_demo_utils.cc valhalla/src/mjolnir/valhalla_traffic_demo_utils.cc
# New CMakeLists that adds valhalla_traffic_demo_utils to the build list
COPY valhalla_code_overwrites/CMakeLists.txt valhalla/CMakeLists.txt
# New src CMakeLists that adds microtar library dependency for the demo utility
COPY valhalla_code_overwrites/src/CMakeLists.txt valhalla/src/CMakeLists.txt

# Build valhalla
RUN mkdir valhalla/build
RUN cd valhalla/build; cmake .. -DCMAKE_BUILD_TYPE=Release
RUN cd valhalla/build; make -j$(nproc)
RUN cd valhalla/build; make install

# Generate routing tiles
RUN mkdir valhalla_tiles
RUN cd valhalla_tiles; wget https://download.geofabrik.de/europe/estonia-latest.osm.pbf -O estonia.osm.pbf

# Generate the config
RUN cd valhalla_tiles; valhalla_build_config --mjolnir-tile-dir ${PWD}/valhalla_tiles --mjolnir-timezone ${PWD}/valhalla_tiles/timezones.sqlite --mjolnir-admin ${PWD}/valhalla_tiles/admins.sqlite --mjolnir-traffic-extract ${PWD}/traffic.tar > valhalla_raw.json
# Remove unused options to keep service output clean of errors
RUN cd valhalla_tiles; sed -e '/elevation/d' -e '/tile_extract/d' valhalla_raw.json > valhalla.json

RUN cd valhalla_tiles; valhalla_build_tiles -c valhalla.json estonia.osm.pbf
RUN cd valhalla_tiles; find valhalla_tiles | sort -n | tar cf valhalla_tiles.tar --no-recursion -T -


###### Add predicted traffic information


# Update routing tiles with traffic information
# Create hierarchy of directories for traffic tiles with the same structure as the graph tiles
RUN cd /valhalla_tiles; mkdir traffic; cd valhalla_tiles; find . -type d -exec mkdir -p -- ../traffic/{} \;

# Generate osm ways to valhalla edges mapping:
RUN cd valhalla_tiles; valhalla_ways_to_edges --config valhalla.json
# ^ This generates a file with mappings at valhalla_tiles/ways_edges.txt. The warning about traffic can be safely ignored.

# In order to find the osm id of a way, go to osm editor, edit, click on road, view on openstreetmap.org, check URL
# Let's update the traffic for openstreetmap.org/way/233161449
# Generate a csv with speeds for all edges
COPY update_traffic.py valhalla_tiles/traffic/update_traffic.py
RUN cd /valhalla_tiles/traffic; python3 update_traffic.py 233161449 /valhalla_tiles/valhalla_tiles/way_edges.txt

# Move the csv file to the expected location in the tile hierarchy
# All valhalla edges for this osm way id have the same tile id, so just get the first one from the mapping
RUN cd /valhalla_tiles/traffic; \
    edge_id=`grep 233161449 /valhalla_tiles/valhalla_tiles/way_edges.txt | cut -d ',' -f3`; \
    mv traffic.csv `valhalla_traffic_demo_utils --get-traffic-dir $edge_id`

# Add traffic information to the routing tiles
RUN cd /valhalla_tiles; valhalla_add_predicted_traffic -t traffic --config valhalla.json


###### Add live traffic information

# Generate the traffic archive
RUN valhalla_traffic_demo_utils --config /valhalla_tiles/valhalla.json --generate-live-traffic 0/3381/0 20 `date +%s`
