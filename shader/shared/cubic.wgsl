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
    local_to_world_xy: vec2<f32>,
    local_to_world_zw: vec2<f32>,
    local_to_world_t: vec2<f32>,
    stroke: vec2<f32>,
    dash_start: u32,
    dash_size: u32,
    length_modifier: f32,
    flags: u32,
}

let CUBIC_IS_STROKE = 1u;

let PATTERN_IN_LOCAL_SPACE: u32 = 0u;
let PATTERN_IN_SCREEN_SPACE: u32 = 1u;
let PARTICLES_IN_WORLD_SPACE: u32 = 2u;