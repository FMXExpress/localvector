#!/bin/sh
# Build localvector with Free Pascal (Delphi mode). Requires FPC 3.2+.
# HTTPS downloads under FPC use OpenSSL (libssl/libcrypto must be installed).
# Note: localvector targets ONNX Runtime; on non-Windows you must provide the
# matching onnxruntime shared library (onnxruntime.so / .dylib) on the loader path.
set -e
fpc -Mdelphi -O2 -Fu. -Fusrc -FE. localvector.dpr
echo
echo "Built ./localvector"
echo "Place a current onnxruntime shared library on the loader path (>= 1.17)."
