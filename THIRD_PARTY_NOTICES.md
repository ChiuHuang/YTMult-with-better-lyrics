# Third-party notices

## MDX23C InstVoc HQ Core ML model

The Sing model is downloaded at runtime from the project's model endpoint and
is not stored in this source repository. The upstream model card identifies
the Core ML package as MIT-licensed and credits ZFTurbo (model/checkpoint),
KUIELab (TFC-TDF v3), Anjok07 (UVR), and NubeAudio (Core ML packaging):

- [Model card and license](https://huggingface.co/huggingsounds/nubeaudio-mdx)
- [Core ML model files](https://huggingface.co/huggingsounds/nubeaudio-mdx/tree/main)

The model must be redistributed with the upstream MIT notice and attribution.
The app's source-separation implementation is separate from the model weights.

## Vitrine audio-stage reference

The player-stage design was studied from [Clone5030/vitrine](https://github.com/Clone5030/vitrine),
which is GPL-3.0. No Vitrine source code has been copied into this repository;
the Sing implementation is written for YouTube Music's player and is covered
by this repository's GPL-3.0 license. Any later adaptation of Vitrine code must
retain its copyright notices and comply with GPL-3.0.
