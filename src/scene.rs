// Copyright 2022 The vello authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Also licensed under MIT license, at your choice.

use skrifa::instance::NormalizedCoord;
use peniko::kurbo::{ Affine, Rect, Shape, Vec2 };
use peniko::{ BrushRef, Color, Fill, Font, Image, kurbo::Stroke, StyleRef };
use vello_encoding::{ Encoding, Glyph, GlyphRun, Patch, Transform, LinearColor };

/// Encoded definition of a scene and associated resources.
#[derive(Default, Clone)]
pub struct Scene {
    data: Encoding,
}

impl Scene {
    /// Creates a new scene.
    pub fn new() -> Self {
        Self::default()
    }
    pub fn reset(&mut self) {
        self.data.reset()
    }
    /// Returns the raw encoded scene data streams.
    pub fn data(&self) -> &Encoding {
        &self.data
    }
    /// Returns the underlying raw encoding.
    pub fn encoding(&self) -> &Encoding {
        &self.data
    }
    //no clips of anykind, supplemetary path or instances are allowed inside pattern.
    //nesting pattern inside another pattern is also not supported.
    //fill, storke, dash, gradient, image should be supported by pattern
    //TODO: add example of gradient and image inside a pattern
    pub fn push_pattern(
        &mut self,
        start: Vec2,
        box_scale: Vec2,
        rotation: f32,
        is_screen_space: bool
    ) {
        self.data.encode_begin_pattern(start, box_scale, rotation, is_screen_space);
    }

    pub fn pop_pattern(&mut self) {
        self.data.encode_end_pattern();
    }

    pub fn push_instance(&mut self){
        self.data.encode_begin_instance_mark();
    }

    pub fn pop_instance(&mut self){
        self.data.encode_end_instance_mark();
    }

    pub fn push_layer_with_supplementary_path(
        &mut self,
        filter_color: (f32, f32, f32, f32),
        transform: Affine,
        shape: &impl Shape
    ) {
        self.push_layer_with_supplement(filter_color, transform, shape, true);
    }

    pub fn push_supplementary_path(&mut self, transform: Affine, shape: &impl Shape) {
        self.data.encode_transform(Transform::from_kurbo(&transform));
        if !self.data.encode_shape(shape, true) {
            // If the shape is invalid, encode a valid empty path.
            self.data.encode_shape(&Rect::new(0.0, 0.0, 0.0, 0.0), true);
        }
        self.data.encode_supplementary_path();
    }

    /// Pushes a new layer bound by the specifed shape and composed with
    /// previous layers using the specified blend mode.
    pub fn push_layer(
        &mut self,
        filter_color: (f32, f32, f32, f32),
        transform: Affine,
        shape: &impl Shape
    ) {
        self.push_layer_with_supplement(filter_color, transform, shape, false);
    }

    fn push_layer_with_supplement(
        &mut self,
        filter_color: (f32, f32, f32, f32),
        transform: Affine,
        shape: &impl Shape,
        with_supplement: bool
    ) {
        let filter_color = LinearColor::new(
            filter_color.0,
            filter_color.1,
            filter_color.2,
            filter_color.3
        );
        self.data.encode_transform(Transform::from_kurbo(&transform));
        self.data.encode_linewidth(-1.0, None);
        if !self.data.encode_shape(shape, true) {
            // If the layer shape is invalid, encode a valid empty path. This suppresses
            // all drawing until the layer is popped.
            self.data.encode_shape(&Rect::new(0.0, 0.0, 0.0, 0.0), true);
        }
        //the last byte was used as the blend flag
        self.data.encode_begin_clip_filter(
            filter_color.pack_color(),
            filter_color.a,
            with_supplement
        );
    }

    /// Pops the current layer.
    pub fn pop_layer(&mut self) {
        self.data.encode_end_clip();
    }

    /// Fills a shape using the specified style and brush.
    pub fn fill<'b>(
        &mut self,
        style: Fill,
        transform: Affine,
        brush: impl Into<BrushRef<'b>>,
        brush_transform: Option<Affine>,
        shape: &impl Shape
    ) {
        self.data.encode_transform(Transform::from_kurbo(&transform));
        self.data.encode_linewidth(
            match style {
                Fill::NonZero => -1.0,
                Fill::EvenOdd => -2.0,
            },
            None
        );
        if self.data.encode_shape(shape, true) {
            if let Some(brush_transform) = brush_transform {
                if
                    self.data.encode_transform(
                        Transform::from_kurbo(&(transform * brush_transform))
                    )
                {
                    self.data.swap_last_path_tags();
                }
            }
            self.data.encode_brush(brush, 1.0);
        }
    }
    //TODO modify Stroke in peniko and remove this function
    pub fn stroke_dash<'b>(
        &mut self,
        style: &Stroke,
        transform: Affine,
        brush: impl Into<BrushRef<'b>>,
        brush_transform: Option<Affine>,
        shape: &impl Shape,
        dash_array: Vec<f32>
    ) {
        self.data.encode_transform(Transform::from_kurbo(&transform));
        self.data.encode_linewidth(style.width as f32, None);
        self.data.encode_linewidth(style.width as f32, Some(dash_array));
        if self.data.encode_shape(shape, false) {
            if let Some(brush_transform) = brush_transform {
                if
                    self.data.encode_transform(
                        Transform::from_kurbo(&(transform * brush_transform))
                    )
                {
                    self.data.swap_last_path_tags();
                }
            }
            self.data.encode_brush(brush, 1.0);
        }
    }
    /// Strokes a shape using the specified style and brush.
    pub fn stroke<'b>(
        &mut self,
        style: &Stroke,
        transform: Affine,
        brush: impl Into<BrushRef<'b>>,
        brush_transform: Option<Affine>,
        shape: &impl Shape
    ) {
        self.data.encode_transform(Transform::from_kurbo(&transform));
        self.data.encode_linewidth(style.width as f32, None);
        if self.data.encode_shape(shape, false) {
            if let Some(brush_transform) = brush_transform {
                if
                    self.data.encode_transform(
                        Transform::from_kurbo(&(transform * brush_transform))
                    )
                {
                    self.data.swap_last_path_tags();
                }
            }
            self.data.encode_brush(brush, 1.0);
        }
    }

    /// Draws an image at its natural size with the given transform.
    pub fn draw_image(&mut self, image: &Image, transform: Affine) {
        self.fill(
            Fill::NonZero,
            transform,
            image,
            None,
            &Rect::new(0.0, 0.0, image.width as f64, image.height as f64)
        );
    }

    /// Returns a builder for encoding a glyph run.
    pub fn draw_glyphs(&mut self, font: &Font) -> DrawGlyphs {
        DrawGlyphs::new(&mut self.data, font)
    }

    pub fn set_transform(&mut self, transform: Affine) {
        self.data.set_transform(&Transform::from_kurbo(&transform));
    }

    /// Appends a fragment to the scene.
    pub fn append(&mut self, fragment: &Scene, transform: Option<Affine>) {
        self.data.append(&fragment.data, &transform.map(|xform| Transform::from_kurbo(&xform)));
    }
}

/// Builder for encoding a glyph run.
pub struct DrawGlyphs<'a> {
    encoding: &'a mut Encoding,
    run: GlyphRun,
    brush: BrushRef<'a>,
    brush_alpha: f32,
}

impl<'a> DrawGlyphs<'a> {
    /// Creates a new builder for encoding a glyph run for the specified
    /// encoding with the given font.
    pub fn new(encoding: &'a mut Encoding, font: &Font) -> Self {
        let coords_start = encoding.resources.normalized_coords.len();
        let glyphs_start = encoding.resources.glyphs.len();
        let stream_offsets = encoding.stream_offsets();
        Self {
            encoding,
            run: GlyphRun {
                font: font.clone(),
                transform: Transform::IDENTITY,
                glyph_transform: None,
                font_size: 16.0,
                hint: false,
                normalized_coords: coords_start..coords_start,
                style: Fill::NonZero.into(),
                glyphs: glyphs_start..glyphs_start,
                stream_offsets,
            },
            brush: Color::BLACK.into(),
            brush_alpha: 1.0,
        }
    }

    /// Sets the global transform. This is applied to all glyphs after the offset
    /// translation.
    ///
    /// The default value is the identity matrix.
    pub fn transform(mut self, transform: Affine) -> Self {
        self.run.transform = Transform::from_kurbo(&transform);
        self
    }

    /// Sets the per-glyph transform. This is applied to all glyphs prior to
    /// offset translation. This is common used for applying a shear to simulate
    /// an oblique font.
    ///
    /// The default value is `None`.
    pub fn glyph_transform(mut self, transform: Option<Affine>) -> Self {
        self.run.glyph_transform = transform.map(|xform| Transform::from_kurbo(&xform));
        self
    }

    /// Sets the font size in pixels per em units.
    ///
    /// The default value is 16.0.
    pub fn font_size(mut self, size: f32) -> Self {
        self.run.font_size = size;
        self
    }

    /// Sets whether to enable hinting.
    ///
    /// The default value is `false`.
    pub fn hint(mut self, hint: bool) -> Self {
        self.run.hint = hint;
        self
    }

    /// Sets the normalized design space coordinates for a variable font instance.
    pub fn normalized_coords(mut self, coords: &[NormalizedCoord]) -> Self {
        self.encoding.resources.normalized_coords.truncate(self.run.normalized_coords.start);
        self.encoding.resources.normalized_coords.extend_from_slice(coords);
        self.run.normalized_coords.end = self.encoding.resources.normalized_coords.len();
        self
    }

    /// Sets the brush.
    ///
    /// The default value is solid black.
    pub fn brush(mut self, brush: impl Into<BrushRef<'a>>) -> Self {
        self.brush = brush.into();
        self
    }

    /// Sets an additional alpha multiplier for the brush.
    ///
    /// The default value is 1.0.
    pub fn brush_alpha(mut self, alpha: f32) -> Self {
        self.brush_alpha = alpha;
        self
    }

    /// Encodes a fill or stroke for for the given sequence of glyphs and consumes
    /// the builder.
    ///
    /// The `style` parameter accepts either `Fill` or `&Stroke` types.
    pub fn draw(mut self, style: impl Into<StyleRef<'a>>, glyphs: impl Iterator<Item = Glyph>) {
        let resources = &mut self.encoding.resources;
        self.run.style = style.into().to_owned();
        resources.glyphs.extend(glyphs);
        self.run.glyphs.end = resources.glyphs.len();
        if self.run.glyphs.is_empty() {
            resources.normalized_coords.truncate(self.run.normalized_coords.start);
            return;
        }
        let index = resources.glyph_runs.len();
        resources.glyph_runs.push(self.run);
        resources.patches.push(Patch::GlyphRun { index });
        self.encoding.encode_brush(self.brush, self.brush_alpha);
    }
}
