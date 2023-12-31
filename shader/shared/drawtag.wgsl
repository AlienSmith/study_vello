// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// The DrawMonoid is computed as a prefix sum to aid in decoding
// the variable-length encoding of draw objects.
struct DrawMonoid {
    // The number of paths preceding this draw object.
    path_ix: u32,
    // The number of clip operations preceding this draw object.
    clip_ix: u32,
    // The offset of the encoded draw object in the scene (u32s).
    scene_offset: u32,
    // The offset of the associated info.
    info_offset: u32,
    // The number of pattern operations preceding this draw object.
    pattern_ix: u32,
}

// Each draw object has a 32-bit draw tag, which is a bit-packed
// version of the draw monoid.
let DRAWTAG_NOP = 0u;
let DRAWTAG_FILL_COLOR = 0x44u;
let DRAWTAG_FILL_LIN_GRADIENT = 0x114u;
let DRAWTAG_FILL_RAD_GRADIENT = 0x29cu;
let DRAWTAG_FILL_IMAGE = 0x248u;
let DRAWTAG_BEGIN_CLIP = 0x9u;
let DRAWTAG_END_CLIP = 0x21u;
let DRAWTAG_BEGIN_PATTERN = 0x400u;
let DRAWTAG_END_PATTERN = 0xC00u;

fn draw_monoid_identity() -> DrawMonoid {
    return DrawMonoid();
}

fn combine_draw_monoid(a: DrawMonoid, b: DrawMonoid) -> DrawMonoid {
    var c: DrawMonoid;
    c.path_ix = a.path_ix + b.path_ix;
    c.clip_ix = a.clip_ix + b.clip_ix;
    c.scene_offset = a.scene_offset + b.scene_offset;
    c.info_offset = a.info_offset + b.info_offset;
    c.pattern_ix = (a.pattern_ix + b.pattern_ix) & (0x7FFFFFFFu) | (a.pattern_ix & 0x80000000u);
    return c;
}

fn map_draw_tag(tag_word: u32) -> DrawMonoid {
    var c: DrawMonoid;
    var pattern_bit = (tag_word >> 10u) & 1u;
    c.path_ix = u32(tag_word != DRAWTAG_NOP) & ~pattern_bit;
    c.clip_ix = tag_word & 1u;
    c.scene_offset = (tag_word >> 2u) & 0x07u;
    c.info_offset = (tag_word >> 6u) & 0x0fu;
    c.pattern_ix = pattern_bit << 31u | pattern_bit;
    return c;
}
