// Translated to Zig from vendor/raven/examples/effects/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - effects
// The effects that come with Raven, and two effects of the application.
//
//   <Border Effect="aurora" EffectColor="#30D158" EffectParams="1,1,1.5"/>
//   <Border Effect="wave.spv"/>                     a shader of the application (wave.frag)
//   <Border Effect="liquid.spv" EffectBackdrop="true"/>   one that reads what is behind it
//
// The .spv files are compiled from the .frag files next to them:
//   glslangValidator -V -I../../include/raven/shaders wave.frag -o wave.spv
// docs/shaders.html is the guide.

const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// #ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR "." / #endif:
// example.RAVEN_EXAMPLE_DIR is always defined (by the generated module example_config).

export fn main() c_int {
    var window: raven.Rid = undefined;
    if (example.example_init("Raven effects") == 0) return 1;
    raven.Rtheme_apply(raven.R_THEME_DARK);
    window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/effects.xml");
    if (window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    if (example.example_automated(window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rshutdown();
    return 0;
}
