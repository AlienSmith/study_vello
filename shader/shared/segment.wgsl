// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

struct Segment {
    origin: vec2<f32>,
    delta: vec2<f32>,
    y_edge: f32,
    next: u32,
    //for dashes
    dash_modifier: f32,
    dash_offset: f32,
    dash_start: u32,
    dash_size: u32,
}
