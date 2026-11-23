# ravenc: the XMLC compiler (an .xmlc file -> one source file). See ravenc.zig and cmake/RavenXMLC.cmake.
# It runs on the build machine and depends on nothing: it is installed in bin/ next to the library.
#
# Seridian: ravenc is the Zig translation of tools/ravenc/ravenc.c (kept as deprecated-c/tools/ravenc/ravenc.c),
# built with `zig build-exe` for the build machine. Its target `ravenc` is a custom target; the program is
# ${RAVEN_RAVENC_EXE} (also in the global property RAVEN_RAVENC_IN_TREE, which raven_target_xmlc uses).
# With the tests, `ravenc_matches_c` compiles the C original and checks that both write the same bytes,
# messages and exit status for every Raven .xml / .xmlc* file and for tests/*.
include(GNUInstallDirs)

if(RAVEN_ZIG_EXECUTABLE)
	set(RAVEN_RAVENC_ZIG "${RAVEN_ZIG_EXECUTABLE}")
else()
	find_program(RAVEN_RAVENC_ZIG zig)
endif()
if(NOT RAVEN_RAVENC_ZIG)
	message(FATAL_ERROR "ravenc is written in Zig: put zig in PATH or set RAVEN_ZIG_EXECUTABLE")
endif()

# (in bin/: the custom target has the name ravenc, a file of that name next to it would clash with Ninja)
set(RAVEN_RAVENC_EXE "${CMAKE_CURRENT_BINARY_DIR}/bin/ravenc${CMAKE_EXECUTABLE_SUFFIX}")
add_custom_command(
	OUTPUT "${RAVEN_RAVENC_EXE}"
	COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/bin"
	COMMAND "${RAVEN_RAVENC_ZIG}" build-exe -OReleaseSafe --name ravenc
		--cache-dir "${CMAKE_CURRENT_BINARY_DIR}/zig-cache"
		"-femit-bin=${RAVEN_RAVENC_EXE}" "${CMAKE_CURRENT_SOURCE_DIR}/ravenc.zig"
	DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ravenc.zig"
	COMMENT "Zig: ravenc"
	VERBATIM)
add_custom_target(ravenc ALL DEPENDS "${RAVEN_RAVENC_EXE}" SOURCES ravenc.zig)
set_target_properties(ravenc PROPERTIES FOLDER "tools")
set_property(GLOBAL PROPERTY RAVEN_RAVENC_IN_TREE "${RAVEN_RAVENC_EXE}")
install(PROGRAMS "${RAVEN_RAVENC_EXE}" DESTINATION ${CMAKE_INSTALL_BINDIR})

if(RAVEN_BUILD_TESTS)
	# the Zig unit tests of ravenc.zig
	add_test(NAME ravenc_unit COMMAND "${RAVEN_RAVENC_ZIG}" test --cache-dir "${CMAKE_CURRENT_BINARY_DIR}/zig-cache"
		"${CMAKE_CURRENT_SOURCE_DIR}/ravenc.zig")
	# the oracle: the C program the Zig one translates
	add_executable(ravenc_c_oracle "${PROJECT_SOURCE_DIR}/deprecated-c/tools/ravenc/ravenc.c")
	set_target_properties(ravenc_c_oracle PROPERTIES C_STANDARD 99 FOLDER "tools")
	if(MSVC)
		target_compile_definitions(ravenc_c_oracle PRIVATE _CRT_SECURE_NO_WARNINGS)
	endif()
	add_dependencies(ravenc_c_oracle ravenc)
	add_test(NAME ravenc_matches_c COMMAND "${CMAKE_COMMAND}"
		"-DZIG_RAVENC=${RAVEN_RAVENC_EXE}" "-DC_RAVENC=$<TARGET_FILE:ravenc_c_oracle>"
		"-DRAVEN_DIR=${PROJECT_SOURCE_DIR}" "-DWORK_DIR=${CMAKE_CURRENT_BINARY_DIR}/compare"
		-P "${CMAKE_CURRENT_SOURCE_DIR}/compare.cmake")
endif()
