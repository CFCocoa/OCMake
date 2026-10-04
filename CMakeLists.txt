# OCMake's own project file. Only used for running OCMake's test suite --
# consumers include OCMake.cmake directly and never need this.

cmake_minimum_required(VERSION 3.25...4.4)
project(OCMake NONE)

if(PROJECT_IS_TOP_LEVEL)
  enable_testing()
  add_subdirectory(tests)
endif()
