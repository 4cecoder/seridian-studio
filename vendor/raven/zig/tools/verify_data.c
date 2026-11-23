/* Writes the embedded fonts of libraven.a to files: verify_data <default.ttf> <mono.ttf>
 * (check.sh compares them with the TTF files of third_party, the files they were embedded from). */
#include <stdio.h>
#include <stddef.h>

extern const unsigned char rvn_default_font_data[];
extern const size_t rvn_default_font_size;
extern const unsigned char rvn_mono_font_data[];
extern const size_t rvn_mono_font_size;

static int dump(const char* path, const unsigned char* data, size_t size) {
	FILE* f = fopen(path, "wb");
	if (!f) return 1;
	size_t written = fwrite(data, 1, size, f);
	fclose(f);
	return written == size ? 0 : 1;
}

int main(int argc, char** argv) {
	if (argc != 3) return 2;
	return dump(argv[1], rvn_default_font_data, rvn_default_font_size) | dump(argv[2], rvn_mono_font_data, rvn_mono_font_size);
}
