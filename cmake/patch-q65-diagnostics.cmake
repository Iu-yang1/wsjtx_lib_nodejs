# Second-stage Q65 diagnostic overlay.
# This keeps the public API stable while making Q65 disk-decode state and
# raw Fortran stdout observable from Node during CI diagnostics.

set(_WSJTX_LIB_DIR "${CMAKE_SOURCE_DIR}/wsjtx_lib")
set(_WSJTX_NATIVE_DIR "${CMAKE_SOURCE_DIR}/native")

# ---- N-API wrapper: options and raw stdout capture -------------------------
set(_wrapper_h "${_WSJTX_NATIVE_DIR}/wsjtx_wrapper.h")
wsjtx_replace_once(
  "${_wrapper_h}"
  "    wsjtx_decode_options_t options_; std::vector<wsjtx_message_t> messages_; int numMessages_ = 0;"
  "    wsjtx_decode_options_t options_; std::vector<wsjtx_message_t> messages_; int numMessages_ = 0;\n    std::vector<std::string> rawOutput_;"
  "store raw decoder output in DecodeWorker")

set(_wrapper_cpp "${_WSJTX_NATIVE_DIR}/wsjtx_wrapper.cpp")
wsjtx_replace_once(
  "${_wrapper_cpp}"
  "#include <stdexcept>\n#include <string>\n#include <vector>"
  "#include <stdexcept>\n#include <string>\n#include <vector>\n#include <mutex>\n#include <sstream>\n#include <cstdio>\n#ifndef _WIN32\n#include <unistd.h>\n#endif"
  "include helpers for raw stdout capture")

set(_capture_helpers [=[
        std::vector<std::string> splitCapturedLines(const std::string& text)
        {
            std::vector<std::string> lines;
            std::istringstream input(text);
            std::string line;
            while (std::getline(input, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (!line.empty()) lines.push_back(line);
            }
            return lines;
        }

#ifndef _WIN32
        std::mutex& stdoutCaptureMutex()
        {
            static std::mutex mutex;
            return mutex;
        }

        template <typename Fn>
        std::vector<std::string> captureStdout(Fn&& fn)
        {
            std::lock_guard<std::mutex> lock(stdoutCaptureMutex());
            fflush(stdout);
            int pipefd[2];
            if (pipe(pipefd) != 0) {
                fn();
                return {};
            }
            int saved = dup(STDOUT_FILENO);
            if (saved < 0) {
                close(pipefd[0]);
                close(pipefd[1]);
                fn();
                return {};
            }
            dup2(pipefd[1], STDOUT_FILENO);
            fn();
            fflush(stdout);
            dup2(saved, STDOUT_FILENO);
            close(saved);
            close(pipefd[1]);
            std::string captured;
            char buffer[4096];
            ssize_t n = 0;
            while ((n = read(pipefd[0], buffer, sizeof(buffer))) > 0) {
                captured.append(buffer, static_cast<size_t>(n));
            }
            close(pipefd[0]);
            return splitCapturedLines(captured);
        }
#endif
]=])
wsjtx_replace_once(
  "${_wrapper_cpp}"
  "        int g_encodeSampleRate = 0;\n\n        int getOptionalInt"
  "        int g_encodeSampleRate = 0;\n${_capture_helpers}\n        int getOptionalInt"
  "add raw stdout capture helpers")

wsjtx_replace_once(
  "${_wrapper_cpp}"
  "        opts.tx_frequency = getOptionalInt(optObj, \"txFrequency\", opts.frequency);"
  "        opts.tx_frequency = getOptionalInt(optObj, \"txFrequency\", opts.frequency);\n        opts.utc = getOptionalInt(optObj, \"utc\", -1);\n        opts.disk_data = getOptionalBoolAsInt(optObj, \"diskData\", mode == WSJTX_MODE_Q65 ? 1 : 0);\n        opts.new_data = getOptionalBoolAsInt(optObj, \"newData\", 1);\n        opts.again = getOptionalBoolAsInt(optObj, \"again\", 0);\n        opts.capture_output = getOptionalBoolAsInt(optObj, \"captureOutput\", mode == WSJTX_MODE_Q65 ? 1 : 0);"
  "read Q65 disk decode diagnostic options")

set(_decode_execute [=[
    void DecodeWorker::Execute()
    {
        auto runDecode = [&]() -> int {
            if (useFloat_) {
                return wsjtx_decode_float_v2(handle_, mode_,
                    floatData_.data(), static_cast<int>(floatData_.size()),
                    &options_);
            }
            return wsjtx_decode_int16_v2(handle_, mode_,
                reinterpret_cast<int16_t*>(intData_.data()),
                static_cast<int>(intData_.size()),
                &options_);
        };

        int rc;
#ifndef _WIN32
        if (options_.capture_output) {
            rc = WSJTX_ERR_EXCEPTION;
            rawOutput_ = captureStdout([&]() { rc = runDecode(); });
        } else {
            rc = runDecode();
        }
#else
        rc = runDecode();
#endif
        if (rc == WSJTX_OK) {
            messages_.resize(MAX_MSGS);
            numMessages_ = wsjtx_pull_messages(handle_, messages_.data(), MAX_MSGS);
        } else {
            SetError("Decode failed with error code " + std::to_string(rc));
        }
    }
]=])
wsjtx_replace_once(
  "${_wrapper_cpp}"
  "    void DecodeWorker::Execute()\n    {\n        int rc;\n        if (useFloat_) {\n            rc = wsjtx_decode_float_v2(handle_, mode_,\n                floatData_.data(), static_cast<int>(floatData_.size()),\n                &options_);\n        } else {\n            rc = wsjtx_decode_int16_v2(handle_, mode_,\n                reinterpret_cast<int16_t*>(intData_.data()),\n                static_cast<int>(intData_.size()),\n                &options_);\n        }\n        if (rc == WSJTX_OK) {\n            messages_.resize(MAX_MSGS);\n            numMessages_ = wsjtx_pull_messages(handle_, messages_.data(), MAX_MSGS);\n        } else {\n            SetError(\"Decode failed with error code \" + std::to_string(rc));\n        }\n    }"
  "${_decode_execute}"
  "capture raw decoder stdout in DecodeWorker")

wsjtx_replace_once(
  "${_wrapper_cpp}"
  "        result.Set(\"messages\", msgs);\n        result.Set(\"success\", Napi::Boolean::New(env, true));"
  "        result.Set(\"messages\", msgs);\n        Napi::Array raw = Napi::Array::New(env, rawOutput_.size());\n        for (size_t i = 0; i < rawOutput_.size(); i++) raw[i] = Napi::String::New(env, rawOutput_[i]);\n        result.Set(\"rawOutput\", raw);\n        result.Set(\"success\", Napi::Boolean::New(env, true));"
  "return rawOutput from DecodeWorker")

# ---- C API -> wsjtx_lib disk controls --------------------------------------
set(_c_api_cpp "${_WSJTX_NATIVE_DIR}/wsjtx_c_api.cpp")
wsjtx_replace_once(
  "${_c_api_cpp}"
  "    lib->setDecodeUtc(opts->utc);"
  "    lib->setDecodeUtc(opts->utc);\n    lib->setDecodeDiskControls(opts->disk_data != 0, opts->new_data != 0, opts->again != 0);"
  "forward disk decode controls through C ABI")

# ---- wsjtx_lib disk-control plumbing ---------------------------------------
set(_lib_h "${_WSJTX_LIB_DIR}/wsjtx_lib.h")
wsjtx_replace_once(
  "${_lib_h}"
  "\tvoid setDecodeUtc(int utc);\n\tvoid setDecodeQ65Controls"
  "\tvoid setDecodeUtc(int utc);\n\tvoid setDecodeDiskControls(bool diskData, bool newData, bool again);\n\tvoid setDecodeQ65Controls"
  "declare wsjtx_lib::setDecodeDiskControls")
wsjtx_replace_once(
  "${_lib_h}"
  "\tint decode_utc_ = -1;\n\tint q65_period_"
  "\tint decode_utc_ = -1;\n\tbool disk_data_ = false;\n\tbool new_data_ = true;\n\tbool again_ = false;\n\tint q65_period_"
  "add wsjtx_lib disk decode state")

set(_lib_cpp "${_WSJTX_LIB_DIR}/wsjtx_lib.cpp")
wsjtx_replace_once(
  "${_lib_cpp}"
  "void wsjtx_lib::setDecodeUtc(int utc)\n{\n\tdecode_utc_ = utc;\n}\n\nvoid wsjtx_lib::setDecodeQ65Controls"
  "void wsjtx_lib::setDecodeUtc(int utc)\n{\n\tdecode_utc_ = utc;\n}\n\nvoid wsjtx_lib::setDecodeDiskControls(bool diskData, bool newData, bool again)\n{\n\tdisk_data_ = diskData;\n\tnew_data_ = newData;\n\tagain_ = again;\n}\n\nvoid wsjtx_lib::setDecodeQ65Controls"
  "implement wsjtx_lib::setDecodeDiskControls")
wsjtx_replace_once(
  "${_lib_cpp}"
  "\tptr->setDecodeUtc(decode_utc_);\n\tptr->setDecodeQ65Controls"
  "\tptr->setDecodeUtc(decode_utc_);\n\tptr->setDecodeDiskControls(disk_data_, new_data_, again_);\n\tptr->setDecodeQ65Controls"
  "forward disk controls to decoder")

# ---- wstjx_decode disk controls and WSJT-X-like params ---------------------
set(_decode_h "${_WSJTX_LIB_DIR}/wsjtx_decode.h")
wsjtx_replace_once(
  "${_decode_h}"
  "\tvoid setDecodeUtc(int utc);\n\tvoid setDecodeQ65Controls"
  "\tvoid setDecodeUtc(int utc);\n\tvoid setDecodeDiskControls(bool diskData, bool newData, bool again);\n\tvoid setDecodeQ65Controls"
  "declare wstjx_decode::setDecodeDiskControls")
wsjtx_replace_once(
  "${_decode_h}"
  "\tint decode_utc_ = -1;\n\tint q65_period_"
  "\tint decode_utc_ = -1;\n\tbool disk_data_ = false;\n\tbool new_data_ = true;\n\tbool again_ = false;\n\tint q65_period_"
  "add wstjx_decode disk decode state")

set(_decode_cpp "${_WSJTX_LIB_DIR}/wsjtx_decode.cpp")
wsjtx_replace_once(
  "${_decode_cpp}"
  "void wstjx_decode::setDecodeUtc(int utc) {\n\tdecode_utc_ = utc;\n}\nvoid wstjx_decode::setDecodeQ65Controls"
  "void wstjx_decode::setDecodeUtc(int utc) {\n\tdecode_utc_ = utc;\n}\nvoid wstjx_decode::setDecodeDiskControls(bool diskData, bool newData, bool again) {\n\tdisk_data_ = diskData;\n\tnew_data_ = newData;\n\tagain_ = again;\n}\nvoid wstjx_decode::setDecodeQ65Controls"
  "implement wstjx_decode::setDecodeDiskControls")
wsjtx_replace_once(
  "${_decode_cpp}"
  "\tparams.nutc = decode_utc_ >= 0 ? decode_utc_ : (local_tm.tm_hour * 10000 + local_tm.tm_min * 100 + local_tm.tm_sec);"
  "\tparams.nutc = decode_utc_ >= 0 ? decode_utc_ : (local_tm.tm_hour * 10000 + local_tm.tm_min * 100 + local_tm.tm_sec);\n\tparams.ndiskdat = disk_data_;\n\tparams.newdat = new_data_;\n\tparams.nagain = again_;"
  "set disk decode params")

include("${CMAKE_SOURCE_DIR}/cmake/patch-q65-input-diagnostics.cmake")
