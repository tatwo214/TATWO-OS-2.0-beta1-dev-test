#pragma once
#include <string>
// Inputs come from native CEF frame/commit state and native UI approval only.
inline bool TatwoAutofillAllowed(const std::string &frame_origin,
                                 const std::string &committed_origin,
                                 bool main_frame, bool user_approved) {
  return main_frame && user_approved &&
      frame_origin.rfind("https://", 0) == 0 && frame_origin.size() > 8 &&
      frame_origin == committed_origin;
}
