#include <cassert>
#include <iostream>

// Different CEF wrappers may represent the same browser. Only the browser's
// stable identity may admit the remaining stages; another browser is refused.
struct Browser {
  int identity;
  bool IsSame(Browser* other) { return other && identity == other->identity; }
};
struct Host {
  Browser* browser;
  Browser* GetBrowser() { return browser; }
};
struct State {
  Browser* browser;
  Host* agent_key_host;
};
#define NO false
bool allowed(State* state, int phase) {
  // INSERT native guard
  return true;
}
int main() {
  Browser first{1}, another_wrapper{1}, foreign{2};
  Host retained{&first}, new_wrapper{&another_wrapper};
  assert(&retained != &new_wrapper);
  State same{&another_wrapper, &retained};
  assert(!allowed(&same, 0));
  assert(allowed(&same, 1));
  assert(allowed(&same, 2));
  State other{&foreign, &retained};
  assert(!allowed(&other, 1));
  assert(!allowed(&other, 2));
  State empty{&first, nullptr};
  assert(allowed(&empty, 0));
  assert(!allowed(&empty, 1));
  assert(!allowed(&empty, 2));
  std::cout << "W328 NATIVE IDENTITY SUMMARY passes=9 failures=0\n";
}
