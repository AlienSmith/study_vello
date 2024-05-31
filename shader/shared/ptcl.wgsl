// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Layout of per-tile command list
// Initial allocation, in u32's.
let PTCL_INITIAL_ALLOC = 64u;
let PTCL_INCREMENT = 64u;

// Amount of space taken by jump
let JUMP_HEADROOM = 2u;

//1 end command + 4 * 2(endclips)
let PTCL_ENDROOM = 9u;

let MAX_LAYER_COUNT = 3u;
//3 layer ends index and its blend alpha
let LAYER_INFOR_SIZE = 6u;

// Tags for PTCL commands
let CMD_DRAW = 1u;
let CMD_BEGIN_CLIP_DIRECT = 2u;
let CMD_DRAW_INDIRECT = 3u;
let CMD_END = 0u;

//Values for original shaders
// Amount of space taken by clips
let PTCL_HEADROOM = 30u;

let CMD_FILL = 1u;
let CMD_STROKE = 2u;
let CMD_SOLID = 3u;
let CMD_COLOR = 5u;
let CMD_LIN_GRAD = 6u;
let CMD_RAD_GRAD = 7u;
let CMD_IMAGE = 8u;
let CMD_BEGIN_CLIP = 9u;
let CMD_END_CLIP = 10u;
let CMD_JUMP = 11u;

// The individual PTCL structs are written here, but read/write is by
// hand in the relevant shaders

struct CmdFill {
    tile: u32,
    backdrop: i32,
}

struct CmdStroke {
    tile: u32,
    half_width: f32,
}

struct CmdJump {
    new_ix: u32,
}

struct CmdColor {
    rgba_color: u32,
}

struct CmdLinGrad {
    index: u32,
    extend_mode: u32,
    line_x: f32,
    line_y: f32,
    line_c: f32,
}

struct CmdRadGrad {
    index: u32,
    extend_mode: u32,
    matrx: vec4<f32>,
    xlat: vec2<f32>,
    focal_x: f32,
    radius: f32,
    kind: u32,
    flags: u32,
}

struct CmdImage {
    matrx: vec4<f32>,
    xlat: vec2<f32>,
    atlas_offset: vec2<f32>,
    extents: vec2<f32>,
}

struct CmdEndClip {
    blend: u32,
    alpha: f32,
}
