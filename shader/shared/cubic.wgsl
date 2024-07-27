// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

struct Cubic {
    p0: vec2<f32>,
    p1: vec2<f32>,
    p2: vec2<f32>,
    p3: vec2<f32>,
    path_ix: u32,
    tag_byte: u32,
}

struct PathInfo{
    loacl_to_screen_xy:vec2<f32>,
    loacl_to_screen_zw:vec2<f32>,
    loacl_to_screen_t:vec2<f32>,
    stroke: vec2<f32>,
    dash_start: u32,
    dash_size: u32,
    length_modifier: f32,
    flags: u32,
}

let CUBIC_IS_STROKE = 1u;