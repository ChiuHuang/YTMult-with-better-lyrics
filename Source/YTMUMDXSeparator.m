// MDX23C preprocessing follows the downloaded model's published I/O contract:
// 44.1 kHz, 8192 FFT, 1024 hop, periodic Hann, reflect-padded centred STFT;
// input [1,4,4096,256] and output [1,2,4,4096,256] (Vocals, Instrumental).
// Model provenance/license: ZFTurbo / UVR, packaged for Core ML by NubeAudio,
// MIT; see the huggingsounds/nubeaudio-mdx model card and repository notices.
#import "YTMUMDXSeparator.h"
#import <Accelerate/Accelerate.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

enum {
    kFFT = YTMUMDXFFTSize,
    kHop = YTMUMDXHopSize,
    kHalf = YTMUMDXFFTSize / 2,
    kPad = YTMUMDXFFTSize / 2,
    kPaddedFrames = YTMUMDXWindowFrames + YTMUMDXFFTSize,
    kInputFeatureCount = 4,
    kStemCount = 2,
};

static NSError *YTMUMDXError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"YTMUMDXSeparator" code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"MDX separator failed"}];
}

static BOOL YTMUMDXShapeMatches(MLFeatureDescription *feature, NSArray<NSNumber *> *expected) {
    if (!feature || feature.type != MLFeatureTypeMultiArray) return NO;
    NSArray<NSNumber *> *shape = feature.multiArrayConstraint.shape;
    if (shape.count != expected.count) return NO;
    for (NSUInteger i = 0; i < shape.count; i++) {
        if (shape[i].integerValue != expected[i].integerValue) return NO;
    }
    return YES;
}

static inline size_t YTMUMDXInputOffset(NSInteger feature, NSInteger bin, NSInteger frame,
                                        NSInteger featureStride, NSInteger binStride, NSInteger frameStride) {
    return (size_t)(feature * featureStride + bin * binStride + frame * frameStride);
}

static inline size_t YTMUMDXOutputOffset(NSInteger stem, NSInteger feature, NSInteger bin, NSInteger frame,
                                         NSInteger stemStride, NSInteger featureStride, NSInteger binStride, NSInteger frameStride) {
    return (size_t)(stem * stemStride + feature * featureStride + bin * binStride + frame * frameStride);
}

@implementation YTMUMDXSeparator {
    MLModel *_model;
    MLMultiArray *_inputArray;
    vDSP_DFT_Setup _forward;
    vDSP_DFT_Setup _inverse;
    float *_window;
    float *_padded;
    float *_frame;
    float *_real;
    float *_imag;
    float *_outReal;
    float *_outImag;
    float *_accum;
    float *_inverseEnvelope;
    NSInteger _inputFeatureStride;
    NSInteger _inputBinStride;
    NSInteger _inputFrameStride;
}

- (nullable instancetype)initWithModel:(MLModel *)model error:(NSError **)error {
    if (error) *error = nil;
    if (!model) {
        if (error) *error = YTMUMDXError(1, @"Core ML model is missing");
        return nil;
    }
    NSDictionary<NSString *, MLFeatureDescription *> *inputs = model.modelDescription.inputDescriptionsByName;
    NSDictionary<NSString *, MLFeatureDescription *> *outputs = model.modelDescription.outputDescriptionsByName;
    if (!YTMUMDXShapeMatches(inputs[@"spectrogram"], @[@1, @4, @4096, @256]) ||
        !YTMUMDXShapeMatches(outputs[@"stems"], @[@1, @2, @4, @4096, @256])) {
        if (error) *error = YTMUMDXError(5, @"This package is not the expected MDX23C model (spectrogram → vocals/instrumental stems)");
        return nil;
    }
    if (!(self = [super init])) return nil;
    _model = model;

    NSError *arrayError = nil;
    _inputArray = [[MLMultiArray alloc] initWithShape:@[@1, @4, @4096, @256]
                                             dataType:MLMultiArrayDataTypeFloat32
                                                error:&arrayError];
    _window = calloc(kFFT, sizeof(float));
    _padded = calloc(kPaddedFrames, sizeof(float));
    _frame = calloc(kFFT, sizeof(float));
    _real = calloc(kHalf, sizeof(float));
    _imag = calloc(kHalf, sizeof(float));
    _outReal = calloc(kHalf, sizeof(float));
    _outImag = calloc(kHalf, sizeof(float));
    _accum = calloc(kPaddedFrames, sizeof(float));
    _inverseEnvelope = calloc(kPaddedFrames, sizeof(float));
    _forward = vDSP_DFT_zrop_CreateSetup(NULL, kFFT, vDSP_DFT_FORWARD);
    _inverse = _forward ? vDSP_DFT_zrop_CreateSetup(_forward, kFFT, vDSP_DFT_INVERSE) : NULL;

    if (!_inputArray || !_window || !_padded || !_frame || !_real || !_imag || !_outReal || !_outImag ||
        !_accum || !_inverseEnvelope || !_forward || !_inverse) {
        NSError *failure = arrayError ?: YTMUMDXError(2, @"Could not allocate MDX audio buffers");
        if (error) *error = failure;
        return nil;
    }
    _inputFeatureStride = _inputArray.strides[1].integerValue;
    _inputBinStride = _inputArray.strides[2].integerValue;
    _inputFrameStride = _inputArray.strides[3].integerValue;

    for (int i = 0; i < kFFT; i++) {
        _window[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * (float)i / (float)kFFT));
    }
    for (int frame = 0; frame < YTMUMDXFrameCount; frame++) {
        float *envelope = _inverseEnvelope + (size_t)frame * kHop;
        for (int i = 0; i < kFFT; i++) envelope[i] += _window[i] * _window[i];
    }
    for (int i = 0; i < kPaddedFrames; i++) {
        if (_inverseEnvelope[i] > 0.0f) _inverseEnvelope[i] = 1.0f / _inverseEnvelope[i];
    }
    return self;
}

- (void)dealloc {
    if (_inverse) vDSP_DFT_DestroySetup(_inverse);
    if (_forward) vDSP_DFT_DestroySetup(_forward);
    free(_window);
    free(_padded);
    free(_frame);
    free(_real);
    free(_imag);
    free(_outReal);
    free(_outImag);
    free(_accum);
    free(_inverseEnvelope);
}

- (void)makePaddedChannel:(const float *)input channel:(NSUInteger)channel {
    for (NSUInteger i = 0; i < YTMUMDXWindowFrames; i++) {
        _padded[kPad + i] = input[2 * i + channel];
    }
    for (NSUInteger i = 1; i <= kPad; i++) {
        _padded[kPad - i] = input[2 * i + channel];
        _padded[kPad + YTMUMDXWindowFrames - 1 + i] = input[2 * (YTMUMDXWindowFrames - 1 - i) + channel];
    }
}

- (void)analyzeInput:(const float *)input {
    float *data = _inputArray.dataPointer;
    for (NSUInteger channel = 0; channel < 2; channel++) {
        [self makePaddedChannel:input channel:channel];
        DSPSplitComplex split = {_real, _imag};
        NSInteger realFeature = (NSInteger)(2 * channel);
        NSInteger imagFeature = realFeature + 1;
        for (NSInteger t = 0; t < YTMUMDXFrameCount; t++) {
            const float *samples = _padded + (size_t)t * kHop;
            vDSP_vmul(samples, 1, _window, 1, _frame, 1, kFFT);
            vDSP_ctoz((const DSPComplex *)_frame, 2, &split, 1, kHalf);
            vDSP_DFT_Execute(_forward, _real, _imag, _outReal, _outImag);
            data[YTMUMDXInputOffset(realFeature, 0, t, _inputFeatureStride, _inputBinStride, _inputFrameStride)] = _outReal[0] * 0.5f;
            data[YTMUMDXInputOffset(imagFeature, 0, t, _inputFeatureStride, _inputBinStride, _inputFrameStride)] = 0.0f;
            for (NSInteger bin = 1; bin < YTMUMDXBinCount; bin++) {
                data[YTMUMDXInputOffset(realFeature, bin, t, _inputFeatureStride, _inputBinStride, _inputFrameStride)] = _outReal[bin] * 0.5f;
                data[YTMUMDXInputOffset(imagFeature, bin, t, _inputFeatureStride, _inputBinStride, _inputFrameStride)] = _outImag[bin] * 0.5f;
            }
        }
    }
}

- (void)synthesizeStem:(NSInteger)stem channel:(NSUInteger)channel output:(float *)output array:(MLMultiArray *)array {
    memset(_accum, 0, (size_t)kPaddedFrames * sizeof(float));
    NSInteger realFeature = (NSInteger)(2 * channel);
    NSInteger imagFeature = realFeature + 1;
    NSArray<NSNumber *> *strides = array.strides;
    NSInteger stemStride = strides[1].integerValue;
    NSInteger featureStride = strides[2].integerValue;
    NSInteger binStride = strides[3].integerValue;
    NSInteger frameStride = strides[4].integerValue;
    const float *data = array.dataPointer;
    DSPSplitComplex split = {_outReal, _outImag};

    for (NSInteger t = 0; t < YTMUMDXFrameCount; t++) {
        _real[0] = data[YTMUMDXOutputOffset(stem, realFeature, 0, t, stemStride, featureStride, binStride, frameStride)];
        // The model omits the n_fft/2 Nyquist bin, so the inverse uses zero there.
        _imag[0] = 0.0f;
        for (NSInteger bin = 1; bin < kHalf; bin++) {
            _real[bin] = data[YTMUMDXOutputOffset(stem, realFeature, bin, t, stemStride, featureStride, binStride, frameStride)];
            _imag[bin] = data[YTMUMDXOutputOffset(stem, imagFeature, bin, t, stemStride, featureStride, binStride, frameStride)];
        }
        vDSP_DFT_Execute(_inverse, _real, _imag, _outReal, _outImag);
        vDSP_ztoc(&split, 1, (DSPComplex *)_frame, 2, kHalf);
        vDSP_vmul(_frame, 1, _window, 1, _frame, 1, kFFT);
        float scale = 1.0f / (float)kFFT;
        vDSP_vsmul(_frame, 1, &scale, _frame, 1, kFFT);
        vDSP_vadd(_accum + (size_t)t * kHop, 1, _frame, 1, _accum + (size_t)t * kHop, 1, kFFT);
    }
    vDSP_vmul(_accum + kPad, 1, _inverseEnvelope + kPad, 1, output, 1, YTMUMDXWindowFrames);
}

- (BOOL)separateInterleavedStereo:(const float *)input
                            frames:(NSUInteger)frames
                        vocalsLeft:(float *)vocalsLeft
                       vocalsRight:(float *)vocalsRight
                  instrumentalLeft:(float *)instrumentalLeft
                 instrumentalRight:(float *)instrumentalRight
                             error:(NSError **)error {
    if (error) *error = nil;
    if (!input || !vocalsLeft || !vocalsRight || !instrumentalLeft || !instrumentalRight || frames != YTMUMDXWindowFrames) {
        if (error) *error = YTMUMDXError(3, @"MDX23C needs one 261120-frame interleaved stereo window at 44.1 kHz");
        return NO;
    }

    @synchronized (self) {
        [self analyzeInput:input];
        MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"spectrogram": _inputArray} error:error];
        if (!features) return NO;
        id<MLFeatureProvider> prediction = [_model predictionFromFeatures:features error:error];
        MLMultiArray *stems = [prediction featureValueForName:@"stems"].multiArrayValue;
        if (!stems || stems.dataType != MLMultiArrayDataTypeFloat32 || stems.shape.count != 5 ||
            stems.shape[0].integerValue != 1 || stems.shape[1].integerValue != kStemCount ||
            stems.shape[2].integerValue != kInputFeatureCount || stems.shape[3].integerValue != YTMUMDXBinCount ||
            stems.shape[4].integerValue != YTMUMDXFrameCount) {
            if (error) *error = YTMUMDXError(4, @"Core ML returned stems in an unsupported shape or data type");
            return NO;
        }

        [self synthesizeStem:0 channel:0 output:vocalsLeft array:stems];
        [self synthesizeStem:0 channel:1 output:vocalsRight array:stems];
        [self synthesizeStem:1 channel:0 output:instrumentalLeft array:stems];
        [self synthesizeStem:1 channel:1 output:instrumentalRight array:stems];
    }
    return YES;
}
@end
