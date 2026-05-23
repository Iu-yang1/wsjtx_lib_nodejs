/**
 * wsjtx_c_api.h - Pure C interface for wsjtx_lib
 */

#ifndef WSJTX_C_API_H
#define WSJTX_C_API_H

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
  #ifdef WSJTX_CORE_EXPORTS
    #define WSJTX_API __declspec(dllexport)
  #else
    #define WSJTX_API __declspec(dllimport)
  #endif
#else
  #define WSJTX_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void* wsjtx_handle_t;

#define WSJTX_OK                  0
#define WSJTX_ERR_INVALID_HANDLE -1
#define WSJTX_ERR_INVALID_MODE   -2
#define WSJTX_ERR_ENCODE_FAILED  -3
#define WSJTX_ERR_BUFFER_TOO_SMALL -4
#define WSJTX_ERR_INVALID_SAMPLE_RATE -5
#define WSJTX_ERR_EXCEPTION      -99

typedef enum {
    WSJTX_MODE_FT8     = 0,
    WSJTX_MODE_FT4     = 1,
    WSJTX_MODE_JT4     = 2,
    WSJTX_MODE_JT65    = 3,
    WSJTX_MODE_JT9     = 4,
    WSJTX_MODE_FST4    = 5,
    WSJTX_MODE_Q65     = 6,
    WSJTX_MODE_FST4W   = 7,
    WSJTX_MODE_JT65JT9 = 8,
    WSJTX_MODE_WSPR    = 9
} wsjtx_mode_t;

typedef struct {
    int hh;
    int min;
    int sec;
    int snr;
    int freq;
    float sync;
    float dt;
    char msg[64];
} wsjtx_message_t;

typedef struct {
    int freq;
    char rcall[13];
    char rloc[7];
    int quickmode;
    int usehashtable;
    int npasses;
    int subtraction;
} wsjtx_decoder_options_t;

typedef struct {
    double freq;
    float sync;
    float snr;
    float dt;
    float drift;
    int jitter;
    char message[23];
    char call[13];
    char loc[7];
    char pwr[3];
    int cycles;
} wsjtx_decoder_result_t;

typedef struct {
    int threads;
    int q65_period;
    int q65_submode;
} wsjtx_encode_options_t;

typedef struct {
    int frequency;
    int tx_frequency;
    int utc;              /* HHMMSS, or -1 to use current local time */
    int threads;
    int low_freq;
    int high_freq;
    int tolerance;
    int ap_decode;
    int decode_depth;
    int qso_progress;
    int q65_period;
    int q65_submode;
    int q65_max_drift;
    int q65_clear_averaging;
    int q65_single_decode;
    int q65_averaging;
    char mycall[13];
    char mygrid[7];
    char hiscall[13];
    char hisgrid[7];
} wsjtx_decode_options_t;

WSJTX_API wsjtx_handle_t wsjtx_create(void);
WSJTX_API void wsjtx_destroy(wsjtx_handle_t handle);

WSJTX_API int wsjtx_decode_float(wsjtx_handle_t handle, int mode,
    float* samples, int num_samples, int freq, int threads);

WSJTX_API int wsjtx_decode_int16(wsjtx_handle_t handle, int mode,
    int16_t* samples, int num_samples, int freq, int threads);

WSJTX_API int wsjtx_decode_float_v2(wsjtx_handle_t handle, int mode,
    const float* samples, int num_samples,
    const wsjtx_decode_options_t* options);

WSJTX_API int wsjtx_decode_int16_v2(wsjtx_handle_t handle, int mode,
    const int16_t* samples, int num_samples,
    const wsjtx_decode_options_t* options);

WSJTX_API int wsjtx_encode(wsjtx_handle_t handle, int mode, int freq, int sample_rate,
    const char* message,
    float* out_samples, int* out_num_samples, int out_buf_size,
    char* out_message_sent, int out_msg_buf_size);

WSJTX_API int wsjtx_encode_v2(wsjtx_handle_t handle, int mode, int freq, int sample_rate,
    const char* message, const wsjtx_encode_options_t* options,
    float* out_samples, int* out_num_samples, int out_buf_size,
    char* out_message_sent, int out_msg_buf_size);

WSJTX_API int wsjtx_pull_message(wsjtx_handle_t handle, wsjtx_message_t* out_msg);

WSJTX_API int wsjtx_pull_messages(wsjtx_handle_t handle,
    wsjtx_message_t* out_messages, int max_messages);

WSJTX_API int wsjtx_wspr_decode(wsjtx_handle_t handle,
    float* iq_interleaved, int num_iq_samples,
    wsjtx_decoder_options_t* options,
    wsjtx_decoder_result_t* out_results, int max_results);

WSJTX_API int wsjtx_is_encoding_supported(int mode);
WSJTX_API int wsjtx_is_decoding_supported(int mode);
WSJTX_API int wsjtx_get_sample_rate(int mode);
WSJTX_API double wsjtx_get_transmission_duration(int mode);

#ifdef __cplusplus
}
#endif

#endif /* WSJTX_C_API_H */
