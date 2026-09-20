// Cell rendering, in the shape Ghostty uses: one instance per drawn thing,
// four vertices expanded from the vertex id into a quad.
//
// Three passes, because they have to happen in this order:
//
//   1. solid rects  -- cell backgrounds, underlines, the cursor's fill
//   2. text         -- glyphs, sampling one of two atlases
//   3. solid rects  -- strikethrough and the cursor's outline, over the text
//
// Passes 1 and 3 share a pipeline; only the instance list differs. Everything
// is in device pixels, so the grid arithmetic lives in one place on the CPU
// and the shaders stay free of layout rules.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    // Pixels of the drawable.
    float2 screen_size;
    // Pixels of the grayscale and colour atlases.
    float2 atlas_size;
    float2 color_atlas_size;
};

// Expands a vertex id into the corner of a unit quad, drawn as a triangle
// strip:  0 --> 1
//         |   /|
//         2 --> 3
static float2 quad_corner(uint vid) {
    return float2(float(vid == 1 || vid == 3), float(vid == 2 || vid == 3));
}

// Converts a pixel position to clip space, with y growing downward like the
// grid, so nothing upstream has to think in Metal's coordinate system.
static float4 to_clip(float2 pixel, float2 screen_size) {
    float2 normalised = pixel / screen_size;
    return float4(normalised.x * 2.0 - 1.0,
                  1.0 - normalised.y * 2.0,
                  0.0, 1.0);
}

//----------------------------------------------------------------- solid rects

struct SolidVertexIn {
    // Pixel rect: origin then size.
    float2 origin [[attribute(0)]];
    float2 size   [[attribute(1)]];
    uchar4 color  [[attribute(2)]];
};

struct SolidVertexOut {
    float4 position [[position]];
    float4 color [[flat]];
};

vertex SolidVertexOut solid_vertex(uint vid [[vertex_id]],
                                   SolidVertexIn in [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(1)]]) {
    SolidVertexOut out;
    out.position = to_clip(in.origin + quad_corner(vid) * in.size, uniforms.screen_size);
    out.color = float4(in.color) / 255.0;
    return out;
}

fragment float4 solid_fragment(SolidVertexOut in [[stage_in]]) {
    return in.color;
}

//------------------------------------------------------------------------ text

// Which atlas a glyph lives in. Colour glyphs -- emoji -- carry their own
// colour and must not be tinted by the cell's foreground.
enum GlyphAtlasKind : uint8_t {
    ATLAS_GRAYSCALE = 0,
    ATLAS_COLOR = 1,
};

struct TextVertexIn {
    // Where the glyph sits in its atlas, in pixels.
    uint2   glyph_pos  [[attribute(0)]];
    uint2   glyph_size [[attribute(1)]];
    // Pixel offset from the cell's top-left to this bitmap's top-left.
    int2    offset     [[attribute(2)]];
    ushort2 grid_pos   [[attribute(3)]];
    uchar4  color      [[attribute(4)]];
    // cell_size.x, cell_size.y, atlas kind, unused -- packed to keep the
    // instance stride tidy.
    ushort4 cell_and_atlas [[attribute(5)]];
};

struct TextVertexOut {
    float4 position [[position]];
    float4 color [[flat]];
    float2 tex_coord;
    uint8_t atlas [[flat]];
};

vertex TextVertexOut cell_text_vertex(uint vid [[vertex_id]],
                                      TextVertexIn in [[stage_in]],
                                      constant Uniforms &uniforms [[buffer(1)]]) {
    float2 cell_size = float2(in.cell_and_atlas.xy);
    float2 cell_origin = cell_size * float2(in.grid_pos);
    float2 glyph_size = float2(in.glyph_size);

    // The bitmap was rasterised against this cell's own baseline, so placing it
    // is just undoing the margin it was drawn with -- no bearing arithmetic,
    // and nothing that can round a glyph into the neighbouring cell.
    float2 glyph_origin = cell_origin + float2(in.offset);

    float2 corner = quad_corner(vid);
    uint8_t atlas = uint8_t(in.cell_and_atlas.z);
    float2 atlas_size = atlas == ATLAS_COLOR ? uniforms.color_atlas_size : uniforms.atlas_size;

    TextVertexOut out;
    out.position = to_clip(glyph_origin + corner * glyph_size, uniforms.screen_size);
    out.color = float4(in.color) / 255.0;
    out.tex_coord = (float2(in.glyph_pos) + corner * glyph_size) / atlas_size;
    out.atlas = atlas;
    return out;
}

fragment float4 cell_text_fragment(TextVertexOut in [[stage_in]],
                                   texture2d<float> grayscale [[texture(0)]],
                                   texture2d<float> color_atlas [[texture(1)]]) {
    // Nearest, not linear: glyphs are rasterised at exactly the display scale,
    // so every atlas texel maps to one pixel. Filtering would only blur the
    // text and bleed a glyph's padding into the neighbouring cell.
    constexpr sampler atlas_sampler(mag_filter::nearest, min_filter::nearest);

    if (in.atlas == ATLAS_COLOR) {
        // Emoji arrive already coloured and premultiplied; the cell's
        // foreground is irrelevant, but its alpha still controls fading.
        float4 texel = color_atlas.sample(atlas_sampler, in.tex_coord);
        return texel * in.color.a;
    }

    // The grayscale atlas stores coverage, not colour: the glyph's shape
    // modulates the cell's foreground, premultiplied so it blends over
    // whatever the first pass drew.
    float coverage = grayscale.sample(atlas_sampler, in.tex_coord).r * in.color.a;
    return float4(in.color.rgb * coverage, coverage);
}
