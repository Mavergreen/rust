cmake_minimum_required(VERSION 3.16)
set(RUST_VARIANT "native" CACHE STRING "which product this updater updates: native | cross")
if(RUST_VARIANT STREQUAL "native")
  set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "")
  set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "")
  set(_short rust)
  set(_product "Mavericks Rust")
elseif(RUST_VARIANT STREQUAL "cross")
  set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0 CACHE STRING "")
  set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")
  set(_short rust-cross)
  set(_product "Mavericks Rust (cross)")
else()
  message(FATAL_ERROR "RUST_VARIANT must be 'native' or 'cross' (got '${RUST_VARIANT}')")
endif()
project(RustUpdater LANGUAGES OBJC)
find_package(MavericksShipyard REQUIRED)
include(Mavericks)
include(MavericksSparkle)
mavericks_resolve_version(MAV_RUST_VERSION)
# spec: docs/superpowers/specs/2026-09-25-rust-plan3a-conformance-design.md decision 7 -- the
#       generic icon on purpose; updater/ICON-CREDIT.txt has the reason and the exit.
mavericks_add_updater_app(
  PRODUCT ${_short}
  PRODUCT_NAME "${_product}"
  VERSION "${MAV_RUST_VERSION}"
  LOG_PREFIX "MavRustUpdater"
  CONFIRM_TITLE "${_product} updated"
  CONFIRM_BODY "Rust for Mavericks in /usr/local/mavergreen/${_short} was updated."
  ALLOW_GENERIC
)
