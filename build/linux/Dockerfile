ARG BASE
FROM ${BASE}
# platform: clang-22's base image (build/linux in Mavergreen/clang-22) is the family's glibc floor; the
#           build adds only tools that never reach the tarball. fetch_product_pkg.sh unpacks Recaulk's
#           Payload with cpio, verify-relocatable.sh tells Mach-O apart with file, and bootstrap runs
#           ccache. apt reads the snapshot archive at the timestamp the base image pins, so these
#           come from the same archive state as the image's own packages.
RUN apt-get update --error-on=any && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cpio file ccache && \
    rm -rf /var/lib/apt/lists/*
