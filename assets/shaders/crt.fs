#version 330

// CRT post-process for Ceph.Sec.
//
// The whole game composites into one character grid, rasterises to an
// offscreen texture at a fixed virtual resolution, then arrives here. Doing the
// warp exactly once at the end means every panel, window and diagram the game
// ever grows inherits the same glass automatically, and glyphs stay pixel-exact
// right up until the distortion.
//
// Order matters: curve -> sample (with aberration) -> bloom -> scanlines ->
// phosphor mask -> vignette -> flicker. Scanlines are applied in *source*
// space so they land on text rows rather than crawling as the window resizes,
// while the phosphor mask is applied in *screen* space because a real aperture
// grille belongs to the physical tube, not the signal.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

uniform float uTime;
uniform vec2  uResolution;  // virtual resolution of the source texture
uniform float uCurvature;   // barrel amount; higher value = flatter screen
uniform float uScanline;    // scanline depth, 0..1
uniform float uAberration;  // chromatic split at the edges, in texels
uniform float uVignette;    // corner falloff strength
uniform float uBloom;       // phosphor glow amount
uniform float uFlicker;     // mains-hum brightness wobble

out vec4 finalColor;

const float PI = 3.14159265359;

// Barrel distortion. Pushing each axis outward by the square of the *other*
// axis's distance from centre is what gives the corners their pinch.
vec2 curve(vec2 uv, float amount)
{
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) / vec2(amount, amount);
    uv += uv * offset * offset;
    return uv * 0.5 + 0.5;
}

// Cheap separable-ish glow. Nine taps at a wide radius reads as phosphor
// persistence bleeding into neighbouring cells without needing a second pass.
vec3 bloom_sample(vec2 uv, vec2 texel)
{
    vec3 sum = vec3(0.0);
    float weight_total = 0.0;

    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            vec2 o = vec2(float(x), float(y)) * texel * 2.0;
            // Centre-weighted so the glow hugs the stroke instead of smearing.
            float w = 1.0 / (1.0 + float(abs(x) + abs(y)));
            sum += texture(texture0, uv + o).rgb * w;
            weight_total += w;
        }
    }

    return sum / weight_total;
}

void main()
{
    vec2 uv = curve(fragTexCoord, uCurvature);

    // Outside the tube is bezel, not clamped edge pixels.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
    {
        finalColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec2 texel = 1.0 / uResolution;

    // Convergence error grows toward the edges of the tube, so drive the split
    // by distance from centre rather than applying it uniformly.
    vec2 from_center = uv - 0.5;
    float edge = dot(from_center, from_center);
    vec2 split = from_center * uAberration * edge * texel * uResolution.x * 0.01;

    vec3 color;
    color.r = texture(texture0, uv + split).r;
    color.g = texture(texture0, uv).g;
    color.b = texture(texture0, uv - split).b;

    color += bloom_sample(uv, texel) * uBloom;

    // Scanlines in source space: one dark band per virtual pixel row, so they
    // stay locked to the text grid at any window size.
    float scan = sin(uv.y * uResolution.y * PI);
    color *= 1.0 - uScanline * scan * scan;

    // Aperture grille in screen space -- a property of the glass, not the feed.
    float triad = mod(gl_FragCoord.x, 3.0);
    vec3 mask = vec3(0.80);
    if (triad < 1.0)      mask.r = 1.0;
    else if (triad < 2.0) mask.g = 1.0;
    else                  mask.b = 1.0;
    color *= mask;

    color *= 1.0 - uVignette * edge * 2.0;

    // Slow mains hum, plus a faster low-amplitude ripple so it never reads as a
    // clean sine.
    float flicker = 1.0 + uFlicker * (sin(uTime * 8.0) * 0.6 + sin(uTime * 47.0) * 0.4);
    color *= flicker;

    // Lift the floor slightly: unlit phosphor still catches ambient light, and
    // pure black would make the bezel cut look like a rendering bug.
    color += vec3(0.010, 0.018, 0.012);

    finalColor = vec4(color, 1.0) * colDiffuse * fragColor;
}
