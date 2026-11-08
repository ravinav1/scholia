# Remaining accurate-Vision CI failure

The full-Xcode release suite runs, but one OCR case remains failed on GitHub's `xcode-27` Mac. This is not recorded as a pass or silently skipped. Run [42437617202](https://github.com/ravinav1/scholia/actions/runs/42437617202) completed 300 XCTest cases: 298 passed, one optional user-supplied Simulink case skipped, and `AttachmentSafetyTests.testScannedPDFUsesOCR` failed. The independent attachment executable reproduces the same error. Navigation, cache/draft work counts, independent review, SQLite crash/recovery, production packaging, semantic dependencies and standalone math fonts passed.

A separate diagnostic removes Scholia, PDFKit, XCTest and AppKit raster creation from the failing path. It gives Vision a fixed 1600 × 600 CoreGraphics/CoreText image containing a known phrase. The [diagnostic job](https://github.com/ravinav1/scholia/actions/runs/42439971761) records framework errors without changing the native OCR test gate.

| Vision revision 3 mode | Physical test Mac | GitHub Mac |
|---|---|---|
| Accurate, automatic language | Phrase recognized | `TextRecognition.CRImageReaderError`, code 9 |
| Accurate, automatic language, CPU only | Phrase recognized | Same error |
| Accurate, explicit English | Phrase recognized | `Foundation._GenericObjCError`, code 0 |
| Accurate, explicit English, CPU only | Phrase recognized | Same error |
| Fast, explicit English, CPU only | Phrase recognized | Phrase recognized |

The physical Mac runs macOS 27.2 (26B123), M2 Max, 32 GB. The GitHub runner reports macOS 27.0.1 (26A434), arm64, three processors and 7 GB, with Xcode 27.2 / Swift 6.4.2. The evidence isolates a runner-specific accurate-recognition failure independent of the application. It does not establish whether the underlying cause is that OS build, virtualization, model assets, or another framework prerequisite. A CPU-only accurate retry did not resolve it. Fast recognition succeeding is not a pass of the application's accurate OCR contract.

Both original and deterministic image-only PDF fixtures pass the real production OCR and full attachment-ingestion paths on the physical Mac. The corrected XCTest keeps its phrase assertion and additionally checks that the PDF has no text layer and the attachment is complete. No OCR assertion was weakened, and the product's recognition quality was not changed solely to make CI green.

Raw observations are `results/performance/vision-capabilities-{local,ci}.json`; the local production-path checks are in `native-attachment-verification.json`. To reproduce the independent capability probe with a supported Swift toolchain:

```sh
swiftc -O scripts/performance/diagnose-vision.swift -o /tmp/scholia-vision-probe
/tmp/scholia-vision-probe /tmp/scholia-vision-capabilities.json
```

The probe exits successfully after recording all framework outcomes, including failures; it is diagnostic, not an OCR regression pass. The full native release job remains failing until the accurate OCR test succeeds on a compatible runner. Local release XCTest remains unavailable because this Mac has Command Line Tools rather than full Xcode. The standalone production OCR checks are not labeled XCTest.
