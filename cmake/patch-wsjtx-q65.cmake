# Idempotent source overlay for Q65 TX/RX support in the wsjtx_lib submodule.
# The parent package currently consumes boybook/wsjtx_lib as a submodule, so
# these targeted replacements keep the Node binding self-contained without
# requiring a forked submodule URL.

function(wsjtx_replace_once file needle replacement description)
  file(READ "${file}" _content)
  string(FIND "${_content}" "${replacement}" _already)
  if(_already GREATER_EQUAL 0)
    message(STATUS "Q65 patch already applied: ${description}")
    return()
  endif()
  string(FIND "${_content}" "${needle}" _found)
  if(_found LESS 0)
    message(FATAL_ERROR "Q65 patch failed: ${description}; needle not found in ${file}")
  endif()
  string(REPLACE "${needle}" "${replacement}" _content "${_content}")
  file(WRITE "${file}" "${_content}")
  message(STATUS "Applied Q65 patch: ${description}")
endfunction()

set(_WSJTX_LIB_DIR "${CMAKE_SOURCE_DIR}/wsjtx_lib")

# 1) Add the C++ Q65 encoder declaration.
set(_encode_h "${_WSJTX_LIB_DIR}/wsjtx_encode.h")
wsjtx_replace_once(
  "${_encode_h}"
  "\t  std::vector<float> encode_ft4(wsjtxMode mode, int frequency, std::string message, std::string &msgsent, int sampleRate);\n\t  std::vector<float> encode_wspr(wsjtxMode mode, int frequency, std::string message, std::string &msgsent);"
  "\t  std::vector<float> encode_ft4(wsjtxMode mode, int frequency, std::string message, std::string &msgsent, int sampleRate);\n\t  std::vector<float> encode_q65(wsjtxMode mode, int frequency, std::string message, std::string &msgsent, int sampleRate);\n\t  std::vector<float> encode_wspr(wsjtxMode mode, int frequency, std::string message, std::string &msgsent);"
  "declare wsjtx_encode::encode_q65")

# 2) Add the C++ Q65 encoder implementation. Default is Q65-60A: 85 tones,
# 60 s period, 7200 samples/symbol at 12 kHz, 1x tone-spacing submode A.
set(_encode_cpp "${_WSJTX_LIB_DIR}/wsjtx_encode.cpp")
set(_q65_impl [=[
std::vector<float> wsjtx_encode::encode_q65(wsjtxMode mode, int frequency, std::string message, std::string &msgsent, int sampleRate)
{
	std::vector<float> signal;

	int ichk = 0;
	int i3 = -1;
	int n3 = -1;

	std::memset(msg, 0, 38);
	std::memset(sendmsg, 0, 38);
	std::memset(itone, 0, sizeof(itone));
	std::copy_n(message.c_str(), std::min<size_t>(message.size(), 37), msg);

	genq65_(msg, &ichk, sendmsg, const_cast<int *>(itone), &i3, &n3, 37, 37);
	sendmsg[37] = '\0';
	msgsent = std::string(sendmsg);

	const int nsym = 85;
	const int ntrperiod = 60;
	const int nsubmode = 0;                 // Q65A. Tone spacing multiplier = 1.
	int hmod = 1 << nsubmode;
	int nsps = (sampleRate / 12000) * 7200;
	if (nsps <= 0) nsps = 7200;
	float fsample = static_cast<float>(sampleRate);
	float f0 = static_cast<float>(frequency);
	int icmplx = 0;
	int nwave = nsym * nsps;

	signal.assign(static_cast<size_t>(ntrperiod) * static_cast<size_t>(sampleRate), 0.0f);
	std::vector<float> cwave(static_cast<size_t>(nwave) * 2U, 0.0f);
	genwave_(const_cast<int *>(itone), const_cast<int *>(&nsym), &nsps, &nwave,
			 &fsample, &hmod, &f0, &icmplx, cwave.data(), signal.data());
	return signal;
}

]=])
wsjtx_replace_once(
  "${_encode_cpp}"
  "std::vector<float> wsjtx_encode::encode_wspr(wsjtxMode mode, int frequency, std::string message, std::string &msgsent)"
  "${_q65_impl}std::vector<float> wsjtx_encode::encode_wspr(wsjtxMode mode, int frequency, std::string message, std::string &msgsent)"
  "implement wsjtx_encode::encode_q65")

# 3) Route Q65 through wsjtx_lib::encode().
set(_lib_cpp "${_WSJTX_LIB_DIR}/wsjtx_lib.cpp")
wsjtx_replace_once(
  "${_lib_cpp}"
  "\tcase FT4: {\n\t\tauto ptr = std::make_unique<wsjtx_encode>();\n\t\treturn ptr->encode_ft4(mode, frequency, message, messagesend, sampleRate);\n\t}\n\tdefault: return {};"
  "\tcase FT4: {\n\t\tauto ptr = std::make_unique<wsjtx_encode>();\n\t\treturn ptr->encode_ft4(mode, frequency, message, messagesend, sampleRate);\n\t}\n\tcase Q65: {\n\t\tauto ptr = std::make_unique<wsjtx_encode>();\n\t\treturn ptr->encode_q65(mode, frequency, message, messagesend, sampleRate);\n\t}\n\tdefault: return {};"
  "route Q65 encode in wsjtx_lib")

# 4) Route Q65 decoder results into the Node-visible message queue.
set(_callbacks_f90 "${_WSJTX_LIB_DIR}/lib/decode_callbacks.f90")
wsjtx_replace_once(
  "${_callbacks_f90}"
  "    endif\n    call flush(6)\n\n    select type(ctx => this)\n    type is (counting_q65_decoder)"
  "    endif\n    call wsjtx_decoded(nutc,nsnr,dt,nint(freq),decoded)\n    call flush(6)\n\n    select type(ctx => this)\n    type is (counting_q65_decoder)"
  "forward Q65 decode callback into C queue")

# 5) Let the C++ decoder select Q65 mode 66 and use a full 60 s/12 kHz frame.
set(_decode_cpp "${_WSJTX_LIB_DIR}/wsjtx_decode.cpp")
wsjtx_replace_once(
  "${_decode_cpp}"
  "#include <ctime>\n#include <time.h>"
  "#include <ctime>\n#include <time.h>\n#include <algorithm>"
  "include <algorithm> for Q65 frame sizing")
wsjtx_replace_once(
  "${_decode_cpp}"
  "\tcase FT8: params.nmode = 8; break;\n\tcase FT4: params.nmode = 5; break;\n\tdefault: return;"
  "\tcase FT8: params.nmode = 8; break;\n\tcase FT4: params.nmode = 5; break;\n\tcase Q65:\n\t\tparams.nmode = 66;\n\t\tparams.ntrperiod = 60;\n\t\tparams.kin = std::min(static_cast<int>(audiosamples.size()), 60 * 12000);\n\t\tparams.nzhsym = 85;\n\t\tparams.nsubmode = 0;\n\t\tparams.ntxmode = 66;\n\t\tparams.max_drift = 50;\n\t\tbreak;\n\tdefault: return;"
  "select Q65 decoder mode in float path")
wsjtx_replace_once(
  "${_decode_cpp}"
  "\tcase FT8: params.nmode = 8; break;\n\tcase FT4: params.nmode = 5; break;\n\tdefault: return;"
  "\tcase FT8: params.nmode = 8; break;\n\tcase FT4: params.nmode = 5; break;\n\tcase Q65:\n\t\tparams.nmode = 66;\n\t\tparams.ntrperiod = 60;\n\t\tparams.kin = std::min(static_cast<int>(audiosamples.size()), 60 * 12000);\n\t\tparams.nzhsym = 85;\n\t\tparams.nsubmode = 0;\n\t\tparams.ntxmode = 66;\n\t\tparams.max_drift = 50;\n\t\tbreak;\n\tdefault: return;"
  "select Q65 decoder mode in int16 path")
