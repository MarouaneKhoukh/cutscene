/// Per-frame constants shared with the shader. The layout mirrors `Uniforms`
/// in `ShaderSource.composite` field for field: `float2` members first (8-byte
/// alignment), then the `float4`s on a 16-byte boundary, then scalars, padded
/// to a multiple of 16. `Compositor.init` checks the stride against
/// `ShaderSource.uniformsStride`, so a drifted layout fails at launch rather
/// than rendering garbage.
///
/// The ripples are packed one attribute per `float4` (the x of every ring in
/// one vector, the y in the next, and so on) rather than one struct per ring,
/// so the shader indexes them with its loop counter and the Swift side needs
/// no fixed-size tuple.
struct CompositorUniforms {
    var outputSize: SIMD2<Float>
    var cardOrigin: SIMD2<Float>
    var cardSize: SIMD2<Float>
    var viewportOrigin: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    /// The content crop in source uv: the slice of the captured frame that
    /// is the content (window mode); the whole frame otherwise.
    var cropOrigin: SIMD2<Float>
    var cropSize: SIMD2<Float>
    var shadowOffset: SIMD2<Float>
    var cursorOrigin: SIMD2<Float>
    var cursorSize: SIMD2<Float>
    var gradientDirection: SIMD2<Float>
    /// Spacing between the source taps of one output pixel, in source uv.
    var sourceTapStep: SIMD2<Float>
    /// The camera bubble's bounds in output pixels.
    var bubbleOrigin: SIMD2<Float>
    var bubbleSize: SIMD2<Float>
    /// Camera uv = `cameraUVOrigin + q × cameraUVScale` for `q` across the
    /// bubble; the scale's x is negative when the picture is mirrored.
    var cameraUVOrigin: SIMD2<Float>
    var cameraUVScale: SIMD2<Float>
    var cameraTapStep: SIMD2<Float>
    var backgroundFrom: SIMD4<Float>
    var backgroundTo: SIMD4<Float>
    var rippleColor: SIMD4<Float>
    var bubbleBorderColor: SIMD4<Float>
    /// One lane per ring, in output pixels; lanes past `rippleCount` are unused.
    var rippleCenterX: SIMD4<Float>
    var rippleCenterY: SIMD4<Float>
    var rippleRadius: SIMD4<Float>
    var rippleHalfStroke: SIMD4<Float>
    var rippleOpacity: SIMD4<Float>
    var cornerRadius: Float
    var shadowBlur: Float
    var shadowOpacity: Float
    var cursorOpacity: Float
    var gradientHalfLength: Float
    var bubbleCornerRadius: Float
    var bubbleBorderWidth: Float
    /// Peak darkness of the shadow under the bubble; 0 draws none.
    var bubbleShadowOpacity: Float
    var backgroundMode: UInt32
    var sourceFormat: UInt32
    /// Source taps per axis for one output pixel: 1 when not minifying.
    var sourceTapCount: UInt32
    var rippleCount: UInt32
    /// 0 draws no bubble.
    var bubbleMode: UInt32
    var cameraFormat: UInt32
    var cameraTapCount: UInt32

    static let solidBackground: UInt32 = 0
    static let gradientBackground: UInt32 = 1
    static let bgraSource: UInt32 = 0
    static let videoRange420Source: UInt32 = 1
    static let fullRange420Source: UInt32 = 2
    static let noBubble: UInt32 = 0
    static let cameraBubble: UInt32 = 1
    /// Rings the shader draws at most; `ClickRippleSettings.maximumConcurrent`
    /// defaults to the same, and more are dropped oldest first.
    static let maximumRipples = 4
}

/// Metal Shading Language for the compositor, compiled at runtime because the
/// Command Line Tools ship no Metal compiler (platform notes, Toolchain).
public enum ShaderSource {
    /// `sizeof(Uniforms)` in the shader below.
    static let uniformsStride = 352
    static let vertexFunction = "compositorVertex"
    static let fragmentFunction = "compositorFragment"

    /// One fullscreen triangle and one fragment shader that composes every
    /// layer per pixel, in order: background, shadow, screen card, click
    /// ripples, cursor, camera bubble. Positions are in output pixels, so
    /// the same math serves every size.
    public static let composite = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 outputSize;
            float2 cardOrigin;
            float2 cardSize;
            float2 viewportOrigin;
            float2 viewportSize;
            float2 cropOrigin;
            float2 cropSize;
            float2 shadowOffset;
            float2 cursorOrigin;
            float2 cursorSize;
            float2 gradientDirection;
            float2 sourceTapStep;
            float2 bubbleOrigin;
            float2 bubbleSize;
            float2 cameraUVOrigin;
            float2 cameraUVScale;
            float2 cameraTapStep;
            float4 backgroundFrom;
            float4 backgroundTo;
            float4 rippleColor;
            float4 bubbleBorderColor;
            float4 rippleCenterX;
            float4 rippleCenterY;
            float4 rippleRadius;
            float4 rippleHalfStroke;
            float4 rippleOpacity;
            float cornerRadius;
            float shadowBlur;
            float shadowOpacity;
            float cursorOpacity;
            float gradientHalfLength;
            float bubbleCornerRadius;
            float bubbleBorderWidth;
            float bubbleShadowOpacity;
            uint backgroundMode;
            uint sourceFormat;
            uint sourceTapCount;
            uint rippleCount;
            uint bubbleMode;
            uint cameraFormat;
            uint cameraTapCount;
        };

        struct FullscreenVertex {
            float4 position [[position]];
        };

        // One triangle that covers clip space; the rasterizer clips the
        // overhang, so there is no quad seam and no vertex buffer.
        vertex FullscreenVertex compositorVertex(uint vertexID [[vertex_id]]) {
            FullscreenVertex out;
            float2 clip = float2(vertexID == 1 ? 3.0 : -1.0, vertexID == 2 ? 3.0 : -1.0);
            out.position = float4(clip, 0.0, 1.0);
            return out;
        }

        // Signed distance to a rounded box centred at the origin: negative inside.
        static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
            float2 q = abs(p) - halfSize + radius;
            return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        }

        // The frame's soft shadow around a rounded box: the distance field
        // driving a smooth falloff of the blur radius on each side of the
        // offset edge. An analytic shadow costs one distance per pixel where
        // a Gaussian blur would cost dozens of taps.
        static float softShadow(constant Uniforms& u, float2 p, float2 center, float2 halfSize, float radius,
                                float opacity) {
            float distance = roundedBoxDistance(p - center - u.shadowOffset, halfSize, radius);
            return (1.0 - smoothstep(-u.shadowBlur, u.shadowBlur, distance)) * opacity;
        }

        // One bilinear tap of a source as premultiplied RGBA. Shared by the
        // screen and the camera, which arrive in the same formats.
        static float4 sampleSource(uint format, float2 uv, texture2d<float> bgra,
                                   texture2d<float> luma, texture2d<float> chroma, sampler s) {
            if (format == 0) {
                // Premultiplied BGRA, as CoreGraphics and ScreenCaptureKit produce it.
                return bgra.sample(s, uv);
            }
            float y = luma.sample(s, uv).r;
            // 4:2:0 chroma is sited on the left luma sample of each pair
            // (kCVImageBufferChromaLocation_Left, the MPEG-2 and Apple
            // default), so a chroma texel's centre belongs half a luma pixel
            // left of where the shared uv reads it; a quarter chroma texel
            // moves the read back onto the sited position.
            float2 cbcr = chroma.sample(s, uv + float2(0.25 / float(chroma.get_width()), 0.0)).rg;
            float3 yuv;
            if (format == 1) {
                // Video range: luma 16...235 and chroma 16...240 of 255.
                yuv = float3((y - 16.0 / 255.0) * (255.0 / 219.0), (cbcr - 128.0 / 255.0) * (255.0 / 224.0));
            } else {
                yuv = float3(y, cbcr - 128.0 / 255.0);
            }
            // ITU-R BT.709 (Kr 0.2126, Kb 0.0722), the one matrix the
            // compositor accepts; the Swift side rejects buffers tagged otherwise.
            float3 rgb = float3(yuv.x + 1.5748 * yuv.z,
                                yuv.x - 0.1873 * yuv.y - 0.4681 * yuv.z,
                                yuv.x + 1.8556 * yuv.y);
            return float4(saturate(rgb), 1.0);
        }

        // The source under one output pixel. One bilinear tap reads a 2×2
        // texel patch, which skips texels once the output minifies the source
        // past 2×, so text shimmers; a grid of taps spread over the pixel's
        // footprint box-filters it instead. One tap when not minifying.
        static float4 sampleFiltered(uint format, float2 uv, float2 tapStep, uint tapCount, texture2d<float> bgra,
                                     texture2d<float> luma, texture2d<float> chroma, sampler s) {
            uint taps = max(tapCount, 1u);
            float2 first = uv - tapStep * (float(taps - 1) * 0.5);
            float4 sum = float4(0.0);
            for (uint j = 0; j < taps; ++j) {
                for (uint i = 0; i < taps; ++i) {
                    sum += sampleSource(format, first + tapStep * float2(i, j), bgra, luma, chroma, s);
                }
            }
            return sum / float(taps * taps);
        }

        fragment float4 compositorFragment(FullscreenVertex in [[stage_in]],
                                           constant Uniforms& u [[buffer(0)]],
                                           texture2d<float> sourceBGRA [[texture(0)]],
                                           texture2d<float> sourceLuma [[texture(1)]],
                                           texture2d<float> sourceChroma [[texture(2)]],
                                           texture2d<float> cursorSprite [[texture(3)]],
                                           texture2d<float> cameraBGRA [[texture(4)]],
                                           texture2d<float> cameraLuma [[texture(5)]],
                                           texture2d<float> cameraChroma [[texture(6)]],
                                           sampler linearClamp [[sampler(0)]],
                                           sampler spriteTrilinear [[sampler(1)]]) {
            // Window position: output pixels, origin top-left, pixel centres at .5.
            float2 p = in.position.xy;

            // Background.
            float3 color = u.backgroundFrom.rgb;
            if (u.backgroundMode == 1) {
                float t = dot(p - u.outputSize * 0.5, u.gradientDirection) / u.gradientHalfLength * 0.5 + 0.5;
                color = mix(u.backgroundFrom.rgb, u.backgroundTo.rgb, saturate(t));
            }

            // Shadow: the card's own rounded box, offset.
            float2 halfSize = u.cardSize * 0.5;
            float2 cardCenter = u.cardOrigin + halfSize;
            float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
            color *= 1.0 - softShadow(u, p, cardCenter, halfSize, radius, u.shadowOpacity);

            // Card: the source seen through the crop and the camera viewport,
            // masked by the rounded box with a one-pixel linear ramp for
            // anti-aliasing.
            float cardDistance = roundedBoxDistance(p - cardCenter, halfSize, radius);
            float card = saturate(0.5 - cardDistance);
            if (card > 0.0) {
                float2 cardUV = (p - u.cardOrigin) / u.cardSize;
                float2 uv = u.cropOrigin + (u.viewportOrigin + cardUV * u.viewportSize) * u.cropSize;
                float4 source = sampleFiltered(u.sourceFormat, uv, u.sourceTapStep, u.sourceTapCount, sourceBGRA,
                                               sourceLuma, sourceChroma, linearClamp);
                // Premultiplied over the shadowed background, so the
                // transparent parts of a window capture show the background
                // rather than the black a dropped alpha would leave.
                float3 screen = source.rgb + color * (1.0 - source.a);

                // Click ripples: rings with a one-pixel ramp on both edges,
                // oldest first so the newest lands on top, under the cursor
                // and inside the card mask like it.
                for (uint i = 0; i < u.rippleCount; ++i) {
                    float2 center = float2(u.rippleCenterX[i], u.rippleCenterY[i]);
                    float ring = abs(length(p - center) - u.rippleRadius[i]);
                    float coverage = saturate(u.rippleHalfStroke[i] + 0.5 - ring) * u.rippleOpacity[i];
                    screen = mix(screen, u.rippleColor.rgb, coverage);
                }

                // Cursor: premultiplied sprite over the screen, inside the card
                // mask so a cursor leaving the viewport slides off the edge.
                if (u.cursorOpacity > 0.0) {
                    float2 q = (p - u.cursorOrigin) / u.cursorSize;
                    if (all(q >= 0.0) && all(q <= 1.0)) {
                        float4 sprite = cursorSprite.sample(spriteTrilinear, q) * u.cursorOpacity;
                        screen = sprite.rgb + screen * (1.0 - sprite.a);
                    }
                }
                color = mix(color, screen, card);
            }

            // Camera bubble: a rounded box (a circle when the radius is half
            // the side) with its own shadow, an optional border and the
            // camera aspect-filled inside, over everything before it, since it
            // overlays the screen the way a presenter's picture does.
            if (u.bubbleMode != 0) {
                float2 halfBubble = u.bubbleSize * 0.5;
                float2 bubbleCenter = u.bubbleOrigin + halfBubble;
                float bubbleRadius = min(u.bubbleCornerRadius, min(halfBubble.x, halfBubble.y));
                color *= 1.0 - softShadow(u, p, bubbleCenter, halfBubble, bubbleRadius, u.bubbleShadowOpacity);
                float bubbleDistance = roundedBoxDistance(p - bubbleCenter, halfBubble, bubbleRadius);
                float bubble = saturate(0.5 - bubbleDistance);
                if (bubble > 0.0) {
                    // The picture stops `bubbleBorderWidth` inside the edge; the
                    // band between is the border, which a zero width leaves empty.
                    float picture = saturate(0.5 - (bubbleDistance + u.bubbleBorderWidth));
                    color = mix(color, u.bubbleBorderColor.rgb, (bubble - picture) * u.bubbleBorderColor.a);
                    if (picture > 0.0) {
                        float2 q = (p - u.bubbleOrigin) / u.bubbleSize;
                        float2 uv = u.cameraUVOrigin + q * u.cameraUVScale;
                        float4 camera = sampleFiltered(u.cameraFormat, uv, u.cameraTapStep, u.cameraTapCount,
                                                       cameraBGRA, cameraLuma, cameraChroma, linearClamp);
                        float3 shown = camera.rgb + color * (1.0 - camera.a);
                        color = mix(color, shown, picture);
                    }
                }
            }
            return float4(color, 1.0);
        }
        """
}
