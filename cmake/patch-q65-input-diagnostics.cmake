# Q65 input-path diagnostics and fixes.
# The original float decoder path moved the input vector into samplebuffer before
# copying samples into dec_data.d2. After std::move, audiosamples may be empty,
# which makes generated Float32 Q65 round-trip tests meaningless. Keep the input
# available and print the exact Q65 params that reach multimode_decoder_.

set(_WSJTX_LIB_DIR "${CMAKE_SOURCE_DIR}/wsjtx_lib")
set(_decode_cpp "${_WSJTX_LIB_DIR}/wsjtx_decode.cpp")

wsjtx_replace_once(
  "${_decode_cpp}"
  "#include <time.h>\n#include <algorithm>"
  "#include <time.h>\n#include <algorithm>\n#include <cstdio>"
  "include <cstdio> for Q65 parameter diagnostics")

wsjtx_replace_once(
  "${_decode_cpp}"
  "\tsamplebuffer.push(std::move(audiosamples));"
  "\tsamplebuffer.push(WsjTxVector(audiosamples));"
  "preserve Float32 decode samples after samplebuffer push")

wsjtx_replace_once(
  "${_decode_cpp}"
  "\tfor (size_t i = 0; i < audiosamples.size(); i++)\n\t\tdec_data.d2[i] = (short int)(audiosamples[i] * 32768.0f);"
  "\tfor (size_t i = 0; i < audiosamples.size(); i++) {\n\t\tfloat sample = std::clamp(audiosamples[i], -1.0f, 0.9999695f);\n\t\tdec_data.d2[i] = static_cast<short int>(sample * 32768.0f);\n\t}"
  "clamp Float32 samples before Int16 decoder conversion")

set(_q65_param_print [=[
	if (mode == Q65) {
		std::printf("<Q65Params> nmode=%d ntr=%d kin=%d nzhsym=%d nsubmode=%d nfqso=%d nftx=%d nfa=%d nfb=%d ntol=%d ndiskdat=%d newdat=%d nagain=%d ndepth=%d nexp=%d max_drift=%d nclearave=%d nutc=%d\n",
			params.nmode,
			params.ntrperiod,
			params.kin,
			params.nzhsym,
			params.nsubmode,
			params.nfqso,
			params.nftx,
			params.nfa,
			params.nfb,
			params.ntol,
			params.ndiskdat ? 1 : 0,
			params.newdat ? 1 : 0,
			params.nagain ? 1 : 0,
			params.ndepth,
			params.nexp_decode,
			params.max_drift,
			params.nclearave ? 1 : 0,
			params.nutc);
		std::fflush(stdout);
	}
	fftwf_plan_with_nthreads(threads);]=])

wsjtx_replace_once(
  "${_decode_cpp}"
  "\tfftwf_plan_with_nthreads(threads);"
  "${_q65_param_print}"
  "print Q65 params before multimode_decoder")
