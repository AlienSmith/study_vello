// Copyright 2022 The Vello authors
// SPDX-License-Identifier: Apache-2.0 OR MIT

use std::f32::consts::PI;

use crate::math::PatternData;

use super::{DrawColor, DrawTag, PathEncoder, PathTag, Transform};

use peniko::{kurbo::{Shape, Vec2}, BlendMode, BrushRef, Color};


#[cfg(feature = "full")]
use {
    super::{DrawImage, DrawLinearGradient, DrawRadialGradient, Glyph, GlyphRun, Patch},
    fello::NormalizedCoord,
    peniko::{ColorStop, Extend, GradientKind, Image},
};

//TODO move this struct to peniko
#[derive(Clone, Copy)]
pub struct LinearColor{
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}
impl Default for LinearColor{
    fn default() -> Self {
        Self { r: 1.0, g: 1.0, b: 1.0, a: 1.0 }
    }
}
impl  LinearColor {
    pub fn new(r: f32, g:f32, b:f32, a:f32) -> Self {
        Self {
            r,g,b,a
        }
    }

    pub fn pack_color(&self) -> u32{
        let r = (self.r * 255.0) as u32;
        let g = (self.g * 255.0) as u32;
        let b = (self.b * 255.0) as u32;
        let a = (self.a * 255.0) as u32;
        a | (b << 8) | (g << 16) | (r << 24)
    }
}

pub struct TransformState(pub u8);
impl TransformState{
    pub const DEFAULT: Self = Self(0x0);
    pub const IGNORED: Self = Self(0x1);
}

impl Default for TransformState{
    fn default() -> Self {
        TransformState::DEFAULT
    }
}
impl Clone for TransformState{
    fn clone(&self) -> Self {
        Self(self.0)
    }
}
impl PartialEq for TransformState{
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0
    }
}

/// Encoded data streams for a scene.
#[derive(Clone, Default)]
pub struct Encoding {
    /// The path tag stream.
    pub path_tags: Vec<PathTag>,
    /// The path data stream.
    pub path_data: Vec<u8>,
    /// The draw tag stream.
    pub draw_tags: Vec<DrawTag>,
    /// The draw data stream.
    pub draw_data: Vec<u8>,
    /// The transform stream.
    pub transforms: Vec<Transform>,
    /// The line width stream.
    pub linewidths: Vec<f32>,
    /// The dash array stream.
    pub dasharrays: Vec<f32>,
    /// the following transform would be in screen space
    pub transform_state: TransformState,
    /// whether the corresponding transform is in screen space
    pub should_ignore_camera_transforms:Vec<TransformState>, 
    /// The pattern data stream.
    pub pattern_data: Vec<PatternData>,
    /// Late bound resource data.
    #[cfg(feature = "full")]
    pub resources: Resources,
    /// Number of encoded paths.
    pub n_paths: u32,
    /// Number of encoded path segments.
    pub n_path_segments: u32,
    /// Number of encoded clips/layers.
    pub n_clips: u32,
    /// Number of patterns
    pub n_patterns: u32,
    /// Number of unclosed clips/layers.
    pub n_open_clips: u32,
    /// camera_transform
    pub camera_transform: Option<Transform>,
}

fn angle_to_radians(angle: f32) -> f32{
    let angle = angle - 360.0*(angle / 360.0).floor();
    PI * angle/180.0 
}

impl Encoding {
    /// Creates a new encoding.
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns true if the encoding is empty.
    pub fn is_empty(&self) -> bool {
        self.path_tags.is_empty()
    }

    /// Clears the encoding.
    pub fn reset(&mut self, is_fragment: bool) {
        self.pattern_data.clear();
        self.transforms.clear();
        self.should_ignore_camera_transforms.clear();
        self.path_tags.clear();
        self.path_data.clear();
        self.linewidths.clear();
        self.dasharrays.clear();
        self.draw_data.clear();
        self.draw_tags.clear();
        self.n_paths = 0;
        self.n_path_segments = 0;
        self.n_clips = 0;
        self.n_patterns = 0;
        self.n_open_clips = 0;
        #[cfg(feature = "full")]
        self.resources.reset();
        if !is_fragment {
            self.transforms.push(Transform::IDENTITY);
            self.linewidths.push(-1.0);
            self.linewidths.push(0.0);
            self.linewidths.push(0.0);
            self.should_ignore_camera_transforms.push(TransformState::DEFAULT);
        }
    }

    /// Appends another encoding to this one with an optional transform.
    pub fn append(&mut self, other: &Self, transform: &Option<Transform>) {
        #[cfg(feature = "full")]
        let glyph_runs_base = {
            let offsets = self.stream_offsets();
            let stops_base = self.resources.color_stops.len();
            let glyph_runs_base = self.resources.glyph_runs.len();
            let glyphs_base = self.resources.glyphs.len();
            let coords_base = self.resources.normalized_coords.len();
            self.resources
                .glyphs
                .extend_from_slice(&other.resources.glyphs);
            self.resources
                .normalized_coords
                .extend_from_slice(&other.resources.normalized_coords);
            self.resources
                .glyph_runs
                .extend(other.resources.glyph_runs.iter().cloned().map(|mut run| {
                    run.glyphs.start += glyphs_base;
                    run.normalized_coords.start += coords_base;
                    run.stream_offsets.path_tags += offsets.path_tags;
                    run.stream_offsets.path_data += offsets.path_data;
                    run.stream_offsets.draw_tags += offsets.draw_tags;
                    run.stream_offsets.draw_data += offsets.draw_data;
                    run.stream_offsets.transforms += offsets.transforms;
                    run.stream_offsets.linewidths += offsets.linewidths;
                    run.stream_offsets.dasharrays += offsets.dasharrays;
                    run.stream_offsets.patterns += offsets.patterns;
                    run
                }));
            self.resources
                .patches
                .extend(other.resources.patches.iter().map(|patch| match patch {
                    Patch::Ramp {
                        draw_data_offset: offset,
                        stops,
                        extend,
                    } => {
                        let stops = stops.start + stops_base..stops.end + stops_base;
                        Patch::Ramp {
                            draw_data_offset: offset + offsets.draw_data,
                            stops,
                            extend: *extend,
                        }
                    }
                    Patch::GlyphRun { index } => Patch::GlyphRun {
                        index: index + glyph_runs_base,
                    },
                    Patch::Image {
                        image,
                        draw_data_offset,
                    } => Patch::Image {
                        image: image.clone(),
                        draw_data_offset: *draw_data_offset + offsets.draw_data,
                    },
                }));
            self.resources
                .color_stops
                .extend_from_slice(&other.resources.color_stops);
            glyph_runs_base
        };
        self.path_tags.extend_from_slice(&other.path_tags);
        self.path_data.extend_from_slice(&other.path_data);
        self.draw_tags.extend_from_slice(&other.draw_tags);
        self.draw_data.extend_from_slice(&other.draw_data);
        self.should_ignore_camera_transforms.extend_from_slice(&other.should_ignore_camera_transforms);
        self.n_paths += other.n_paths;
        self.n_path_segments += other.n_path_segments;
        self.n_clips += other.n_clips;
        self.n_patterns += other.n_patterns;
        self.n_open_clips += other.n_open_clips;
        if let Some(transform) = *transform {
            let mut ignore_translate = transform;
            ignore_translate.translation = [0.0,0.0];
            self.transforms
                .extend(other.transforms.iter().enumerate().map(|(index,x)| {
                    if other.should_ignore_camera_transforms[index] == TransformState::DEFAULT {
                        transform * *x
                    }else {
                        *x
                    }
                    }));
            #[cfg(feature = "full")]
            for run in &mut self.resources.glyph_runs[glyph_runs_base..] {
                run.transform = transform * run.transform;
            }
            self.camera_transform = Some(transform);
        } else {
            self.transforms.extend_from_slice(&other.transforms);
            self.camera_transform = None;
        }
        self.linewidths.extend_from_slice(&other.linewidths);
        self.dasharrays.extend_from_slice(&other.dasharrays);
        self.pattern_data.extend_from_slice(&other.pattern_data);
    }

    /// Returns a snapshot of the current stream offsets.
    pub fn stream_offsets(&self) -> StreamOffsets {
        StreamOffsets {
            path_tags: self.path_tags.len(),
            path_data: self.path_data.len(),
            draw_tags: self.draw_tags.len(),
            draw_data: self.draw_data.len(),
            transforms: self.transforms.len(),
            linewidths: self.linewidths.len(),
            dasharrays: self.dasharrays.len(),
            patterns: self.pattern_data.len(),
        }
    }

    /// Encodes a linewidth with dash array even bing filled odd being void.
    pub fn encode_linewidth(&mut self, linewidth: f32, dash_array: Option<Vec<f32>>) {
        //TODO add check of same linewidth and dash_array to save space
        let start = self.dasharrays.len();
        if let Some(array) = dash_array{
            self.dasharrays.extend(array);
        }
        let end = self.dasharrays.len();
        self.path_tags.push(PathTag::LINEWIDTH);
        self.linewidths.push(linewidth);
        self.linewidths.push(start as f32);
        self.linewidths.push(end as f32);
    }

    /// Encodes a transform.
    ///
    /// If the given transform is different from the current one, encodes it and
    /// returns true. Otherwise, encodes nothing and returns false.
    pub fn encode_transform(&mut self, transform: Transform) -> bool {
        if self.transforms.last() != Some(&transform) || self.should_ignore_camera_transforms.last() != Some(&self.transform_state){
            self.path_tags.push(PathTag::TRANSFORM);
            self.transforms.push(transform);
            self.should_ignore_camera_transforms.push(self.transform_state.clone());
            true
        } else {
            false
        }
    }

    /// Returns an encoder for encoding a path. If `is_fill` is true, all subpaths will
    /// be automatically closed.
    pub fn encode_path(&mut self, is_fill: bool) -> PathEncoder {
        PathEncoder::new(
            &mut self.path_tags,
            &mut self.path_data,
            &mut self.n_path_segments,
            &mut self.n_paths,
            is_fill,
        )
    }

    /// Encodes a shape. If `is_fill` is true, all subpaths will be automatically closed.
    /// Returns true if a non-zero number of segments were encoded.
    pub fn encode_shape(&mut self, shape: &impl Shape, is_fill: bool) -> bool {
        let mut encoder = self.encode_path(is_fill);
        encoder.shape(shape);
        encoder.finish(true) != 0
    }

    /// Encodes a brush with an optional alpha modifier.
    #[allow(unused_variables)]
    pub fn encode_brush<'b>(&mut self, brush: impl Into<BrushRef<'b>>, alpha: f32) {
        #[cfg(feature = "full")]
        use super::math::point_to_f32;
        match brush.into() {
            BrushRef::Solid(color) => {
                let color = if alpha != 1.0 {
                    color.with_alpha_factor(alpha)
                } else {
                    color
                };
                self.encode_color(DrawColor::new(color));
            }
            #[cfg(feature = "full")]
            BrushRef::Gradient(gradient) => match gradient.kind {
                GradientKind::Linear { start, end } => {
                    self.encode_linear_gradient(
                        DrawLinearGradient {
                            index: 0,
                            p0: point_to_f32(start),
                            p1: point_to_f32(end),
                        },
                        gradient.stops.iter().copied(),
                        alpha,
                        gradient.extend,
                    );
                }
                GradientKind::Radial {
                    start_center,
                    start_radius,
                    end_center,
                    end_radius,
                } => {
                    self.encode_radial_gradient(
                        DrawRadialGradient {
                            index: 0,
                            p0: point_to_f32(start_center),
                            p1: point_to_f32(end_center),
                            r0: start_radius,
                            r1: end_radius,
                        },
                        gradient.stops.iter().copied(),
                        alpha,
                        gradient.extend,
                    );
                }
                GradientKind::Sweep { .. } => {
                    todo!("sweep gradients aren't supported yet!")
                }
            },
            #[cfg(feature = "full")]
            BrushRef::Image(image) => {
                #[cfg(feature = "full")]
                self.encode_image(image, alpha);
            }
            #[cfg(not(feature = "full"))]
            _ => panic!("brushes other than solid require the 'full' feature to be enabled"),
        }
    }

    /// Encodes a solid color brush.
    pub fn encode_color(&mut self, color: DrawColor) {
        self.draw_tags.push(DrawTag::COLOR);
        self.draw_data.extend_from_slice(bytemuck::bytes_of(&color));
    }

    /// Encodes a linear gradient brush.
    #[cfg(feature = "full")]
    pub fn encode_linear_gradient(
        &mut self,
        gradient: DrawLinearGradient,
        color_stops: impl Iterator<Item = ColorStop>,
        alpha: f32,
        extend: Extend,
    ) {
        match self.add_ramp(color_stops, alpha, extend) {
            RampStops::Empty => self.encode_color(DrawColor::new(Color::TRANSPARENT)),
            RampStops::One(color) => self.encode_color(DrawColor::new(color)),
            _ => {
                self.draw_tags.push(DrawTag::LINEAR_GRADIENT);
                self.draw_data
                    .extend_from_slice(bytemuck::bytes_of(&gradient));
            }
        }
    }

    /// Encodes a radial gradient brush.
    #[cfg(feature = "full")]
    pub fn encode_radial_gradient(
        &mut self,
        gradient: DrawRadialGradient,
        color_stops: impl Iterator<Item = ColorStop>,
        alpha: f32,
        extend: Extend,
    ) {
        // Match Skia's epsilon for radii comparison
        const SKIA_EPSILON: f32 = 1.0 / (1 << 12) as f32;
        if gradient.p0 == gradient.p1 && (gradient.r0 - gradient.r1).abs() < SKIA_EPSILON {
            self.encode_color(DrawColor::new(Color::TRANSPARENT));
        }
        match self.add_ramp(color_stops, alpha, extend) {
            RampStops::Empty => self.encode_color(DrawColor::new(Color::TRANSPARENT)),
            RampStops::One(color) => self.encode_color(DrawColor::new(color)),
            _ => {
                self.draw_tags.push(DrawTag::RADIAL_GRADIENT);
                self.draw_data
                    .extend_from_slice(bytemuck::bytes_of(&gradient));
            }
        }
    }

    /// Encodes an image brush.
    #[cfg(feature = "full")]
    pub fn encode_image(&mut self, image: &Image, _alpha: f32) {
        // TODO: feed the alpha multiplier through the full pipeline for consistency
        // with other brushes?
        self.resources.patches.push(Patch::Image {
            image: image.clone(),
            draw_data_offset: self.draw_data.len(),
        });
        self.draw_tags.push(DrawTag::IMAGE);
        self.draw_data
            .extend_from_slice(bytemuck::bytes_of(&DrawImage {
                xy: 0,
                width_height: (image.width << 16) | (image.height & 0xFFFF),
            }));
    }

    /// Encode start of pattern
    /// start is pivot offset from clip boundary
    pub fn encode_begin_pattern(&mut self, start: Vec2, box_scale:Vec2, rotation: f32, is_screen_space: bool){
        self.transform_state = if is_screen_space{
            TransformState::IGNORED
        }else{
            TransformState::DEFAULT
        };
        let radians  = angle_to_radians(rotation);
        let is_screen_space:u32 = 
        if is_screen_space{
            1
        }else{
            0
        };
        self.draw_tags.push(DrawTag::BEGIN_PATTERN);
        self.pattern_data.push(PatternData { start: [start.x as f32, start.y as f32], box_scale: [box_scale.x as f32, box_scale.y as f32], rotate: radians, is_screen_space });
        self.n_patterns += 1;
        self.path_tags.push(PathTag::PATH);
        self.n_paths += 1;
    }

    ///Encode a end of pattern command.
    pub fn encode_end_pattern(&mut self){
        self.transform_state = TransformState::DEFAULT;
        self.draw_tags.push(DrawTag::END_PATTERN);
        self.n_patterns += 1;
        self.path_tags.push(PathTag::PATH);
        self.n_paths += 1;
    }

    /// Encodes a begin clip command.
    pub fn encode_begin_clip(&mut self, blend_mode: BlendMode, alpha: f32) {
        use super::DrawBeginClip;
        self.draw_tags.push(DrawTag::BEGIN_CLIP);
        self.draw_data
            .extend_from_slice(bytemuck::bytes_of(&DrawBeginClip::new(blend_mode, alpha)));
        self.n_clips += 1;
        self.n_open_clips += 1;
    }

    /// Encodes a begin clip command.
    pub fn encode_begin_clip_filter(&mut self, packed_color: u32, alpha: f32) {
        use super::DrawBeginClip;
        self.draw_tags.push(DrawTag::BEGIN_CLIP);
        self.draw_data
            .extend_from_slice(bytemuck::bytes_of(&DrawBeginClip::new_filter(packed_color, alpha)));
        self.n_clips += 1;
        self.n_open_clips += 1;
    }

    /// Encodes an end clip command.
    pub fn encode_end_clip(&mut self) {
        if self.n_open_clips > 0 {
            self.draw_tags.push(DrawTag::END_CLIP);
            // This is a dummy path, and will go away with the new clip impl.
            self.path_tags.push(PathTag::PATH);
            self.n_paths += 1;
            self.n_clips += 1;
            self.n_open_clips -= 1;
        }
    }

    // Swap the last two tags in the path tag stream; used for transformed
    // gradients.
    pub fn swap_last_path_tags(&mut self) {
        let len = self.path_tags.len();
        self.path_tags.swap(len - 1, len - 2);
    }

    #[cfg(feature = "full")]
    fn add_ramp(
        &mut self,
        color_stops: impl Iterator<Item = ColorStop>,
        alpha: f32,
        extend: Extend,
    ) -> RampStops {
        let offset = self.draw_data.len();
        let stops_start = self.resources.color_stops.len();
        if alpha != 1.0 {
            self.resources
                .color_stops
                .extend(color_stops.map(|stop| stop.with_alpha_factor(alpha)));
        } else {
            self.resources.color_stops.extend(color_stops);
        }
        let stops_end = self.resources.color_stops.len();
        match stops_end - stops_start {
            0 => RampStops::Empty,
            1 => RampStops::One(self.resources.color_stops.pop().unwrap().color),
            _ => {
                self.resources.patches.push(Patch::Ramp {
                    draw_data_offset: offset,
                    stops: stops_start..stops_end,
                    extend,
                });
                RampStops::Many
            }
        }
    }
}

/// Result for adding a sequence of color stops.
enum RampStops {
    /// Color stop sequence was empty.
    Empty,
    /// Contained a single color stop.
    One(Color),
    /// More than one color stop.
    Many,
}

/// Encoded data for late bound resources.
#[cfg(feature = "full")]
#[derive(Clone, Default)]
pub struct Resources {
    /// Draw data patches for late bound resources.
    pub patches: Vec<Patch>,
    /// Color stop collection for gradients.
    pub color_stops: Vec<ColorStop>,
    /// Positioned glyph buffer.
    pub glyphs: Vec<Glyph>,
    /// Sequences of glyphs.
    pub glyph_runs: Vec<GlyphRun>,
    /// Normalized coordinate buffer for variable fonts.
    pub normalized_coords: Vec<NormalizedCoord>,
}

#[cfg(feature = "full")]
impl Resources {
    fn reset(&mut self) {
        self.patches.clear();
        self.color_stops.clear();
        self.glyphs.clear();
        self.glyph_runs.clear();
        self.normalized_coords.clear();
    }
}

/// Snapshot of offsets for encoded streams.
#[derive(Copy, Clone, Default, Debug)]
pub struct StreamOffsets {
    /// Current length of path tag stream.
    pub path_tags: usize,
    /// Current length of path data stream.
    pub path_data: usize,
    /// Current length of draw tag stream.
    pub draw_tags: usize,
    /// Current length of draw data stream.
    pub draw_data: usize,
    /// Current length of transform stream.
    pub transforms: usize,
    /// Current length of linewidth stream.
    pub linewidths: usize,
    /// Current length of dash array.
    pub dasharrays: usize,
    /// Current length of pattern stream.
    pub patterns: usize,
}

impl StreamOffsets {
    #[cfg(feature = "full")]
    pub(crate) fn add(&mut self, other: &Self) {
        self.path_tags += other.path_tags;
        self.path_data += other.path_data;
        self.draw_tags += other.draw_tags;
        self.draw_data += other.draw_data;
        self.transforms += other.transforms;
        self.linewidths += other.linewidths;
        self.dasharrays += other.dasharrays;
        self.patterns += other.patterns;
    }
}
