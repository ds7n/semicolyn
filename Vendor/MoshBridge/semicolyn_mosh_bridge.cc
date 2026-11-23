// SPDX-FileCopyrightText: 2017-2026 Blink Shell contributors
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Derived from extern/mosh/src/frontend/moshiosbridge.cc (blinksh/mosh). The session
// logic is unchanged; the only difference is that the caught exception's text goes to
// the caller's buffer rather than to stderr. Compiled into Mosh.xcframework by
// scripts/build-mosh-xcframework.sh, against the vendored tree (extern/mosh is not
// modified).
#include "src/frontend/iosclient.h"
#include "src/util/locale_utils.h"
#include "semicolyn_mosh_bridge.h"

#include <string>

static void write_error( char* error_buf, size_t error_buf_size, const char* prefix, const char* what )
{
  if ( !error_buf || error_buf_size == 0 ) {
    return;
  }
  snprintf( error_buf, error_buf_size, "%s%s", prefix, what );
}

extern "C" int semicolyn_mosh_main( FILE* f_in,
                                    FILE* f_out,
                                    struct winsize* window_size,
                                    void ( *state_callback )( const void*, const void*, size_t ),
                                    void* state_callback_context,
                                    const char* ip,
                                    const char* port,
                                    const char* key,
                                    const char* predict_mode,
                                    const char* encoded_state_buffer,
                                    size_t encoded_state_size,
                                    const char* predict_overwrite,
                                    char* error_buf,
                                    size_t error_buf_size )
{
  if ( error_buf && error_buf_size > 0 ) {
    error_buf[0] = '\0';
  }
  /* Adopt native locale */
  set_native_locale();

  std::string encoded_state = std::string( encoded_state_buffer, encoded_state_size );

  bool success = false;
  try {
    iOSClient client( fileno( f_in ),
                      f_out,
                      window_size,
                      state_callback,
                      state_callback_context,
                      ip,
                      port,
                      key,
                      predict_mode,
                      0,
                      predict_overwrite );

    client.init();

    try {
      success = client.main( encoded_state );
    } catch ( ... ) {
      client.shutdown();
      throw;
    }

    client.shutdown();
  } catch ( const Network::NetworkException& e ) {
    write_error( error_buf, error_buf_size, "Network exception: ", e.what() );
    success = false;
  } catch ( const Crypto::CryptoException& e ) {
    write_error( error_buf, error_buf_size, "Crypto exception: ", e.what() );
    success = false;
  } catch ( const std::exception& e ) {
    write_error( error_buf, error_buf_size, "Error: ", e.what() );
    success = false;
  }

  return !success;
}
