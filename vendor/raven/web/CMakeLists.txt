# Raven Web: web pages inside a Raven interface (see include/raven_web.h).
#
# The web sources are compiled into the Raven library itself (see the root
# CMakeLists.txt, RAVEN_BUILD_WEB): there is one library, raven::raven.
# raven::web stays as a name for the programs that already link with it:
# it brings nothing more than raven::raven.
#
#   target_link_libraries(app PRIVATE raven::raven)       # #include <raven_web.h>

add_library(raven_web INTERFACE)
target_link_libraries(raven_web INTERFACE raven)
set_target_properties(raven_web PROPERTIES EXPORT_NAME web)
add_library(raven::web ALIAS raven_web)

install(TARGETS raven_web EXPORT ravenTargets)
install(FILES include/raven_web.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(NOT RAVEN_WITH_STB_IMAGE)
	message(WARNING "raven_web: Raven is built without its image decoder (RAVEN_WITH_STB_IMAGE=OFF): web views will work but show nothing, the pictures of the pages cannot be decoded.")
endif()

# The test: the parts that need no browser always run; the rest is reported
# as skipped on a machine without a browser of the Chromium family.
# (Seridian) tests/test_web.zig, the translation of tests/test_web.c, is compiled by zig into an object with the C
# `main`, and linked with the library like the C test was. The rw_* functions it calls are those of the library.
if(RAVEN_BUILD_TESTS)
	if(RAVEN_ZIG_EXECUTABLE)
		set(_rw_zig "${RAVEN_ZIG_EXECUTABLE}")
	else()
		find_program(RAVEN_WEB_ZIG zig)
		set(_rw_zig "${RAVEN_WEB_ZIG}")
	endif()
	if(NOT _rw_zig)
		message(FATAL_ERROR "raven_web: test_web is written in Zig: put zig in PATH or set RAVEN_ZIG_EXECUTABLE")
	endif()
	set(_rw_dir "${CMAKE_CURRENT_BINARY_DIR}/test_web_zig")
	set(_rw_options "${_rw_dir}/test_web_options.zig")
	if(RAVEN_WITH_STB_IMAGE)
		set(_rw_options_text "pub const no_image_decoder = false;\n")
	else()
		set(_rw_options_text "pub const no_image_decoder = true;\n")
	endif()
	file(WRITE "${_rw_options}.tmp" "${_rw_options_text}")
	configure_file("${_rw_options}.tmp" "${_rw_options}" COPYONLY)
	set(_rw_object "${_rw_dir}/test_web${CMAKE_C_OUTPUT_EXTENSION}")
	set(_rw_args build-obj -OReleaseSafe -lc -fno-stack-check)
	if(NOT WIN32)
		list(APPEND _rw_args -fPIC)
	endif()
	if(RAVEN_ZIG_TARGET)
		list(APPEND _rw_args -target ${RAVEN_ZIG_TARGET})
	endif()
	set(_rw_zigsrc "${PROJECT_SOURCE_DIR}/zig/src")
	list(APPEND _rw_args --name test_web --cache-dir "${_rw_dir}/cache"
		--dep raven --dep raven_web --dep web_internal --dep test_web_options
		"-Mroot=${CMAKE_CURRENT_SOURCE_DIR}/tests/test_web.zig"
		"-Mraven=${_rw_zigsrc}/raven/raven.zig"
		--dep raven "-Mraven_web=${_rw_zigsrc}/web/raven_web_h.zig"
		"-Mweb_internal=${_rw_zigsrc}/web/web_internal_h.zig"
		"-Mtest_web_options=${_rw_options}"
		"-femit-bin=${_rw_object}")
	add_custom_command(
		OUTPUT "${_rw_object}"
		COMMAND "${CMAKE_COMMAND}" -E make_directory "${_rw_dir}"
		COMMAND "${_rw_zig}" ${_rw_args}
		DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tests/test_web.zig" "${_rw_zigsrc}/raven/raven.zig"
			"${_rw_zigsrc}/web/raven_web_h.zig" "${_rw_zigsrc}/web/web_internal_h.zig" "${_rw_options}"
		COMMENT "Zig: test_web"
		VERBATIM)
	set_source_files_properties("${_rw_object}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
	add_executable(test_web "${_rw_object}")
	target_link_libraries(test_web PRIVATE raven::raven)
	set_target_properties(test_web PROPERTIES LINKER_LANGUAGE C FOLDER "tests")
	if(NOT WIN32)
		target_link_libraries(test_web PRIVATE m)
	endif()
	add_test(NAME test_web COMMAND test_web)
	set_tests_properties(test_web PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 180)
endif()
