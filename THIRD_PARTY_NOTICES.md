# Third-party notices

## glance (MIT)

The optional face unlock feature adapts code from **glance** by Jonathan Zhou,
<https://github.com/jonnyoo/glance>: face detection and alignment, the ArcFace Core ML
embedder, the geometry/glare/device-bezel liveness analysis (`Sources/SoftLock/FaceLiveness/`),
the camera feed, and `scripts/convert_arcface.py`. Modified for SoftLock.

```
MIT License

Copyright (c) 2026 Jonathan Zhou

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ArcFace model weights (InsightFace `w600k_mbf`)

`Models/ArcFace.mlpackage` is the InsightFace `buffalo_s` recognition model (`w600k_mbf`,
MobileFaceNet trained with ArcFace loss) converted to Core ML. It is **not** covered by the
MIT license above. InsightFace states that its pretrained models are available for
non-commercial research purposes only. Check the terms at
<https://github.com/deepinsight/insightface> before distributing SoftLock builds that include
this model commercially, and swap in a model whose license fits your use.
