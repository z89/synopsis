#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float fadeL;
    float fadeR;
    float edge;
};
layout(binding = 1) uniform sampler2D source;
void main() {
    float x = qt_TexCoord0.x;
    float l = mix(1.0, smoothstep(0.0, edge, x), fadeL);
    float r = mix(1.0, smoothstep(0.0, edge, 1.0 - x), fadeR);
    fragColor = texture(source, qt_TexCoord0) * (l * r * qt_Opacity);
}
