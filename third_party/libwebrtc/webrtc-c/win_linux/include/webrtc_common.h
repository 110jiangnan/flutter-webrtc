#ifndef WEBRTC_COMMON_HXX
#define WEBRTC_COMMON_HXX

/* 对应 flutter_common.h: 跨边界通用工具。
 * 这里只放纯 C++ 工具(极简 JSON 解析/序列化 + 字符串跨 DLL 助手),
 * 不依赖 libwebrtc。 */
#include <cstdint>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

namespace webrtc {

// ================= 极简 JSON(解析配置/约束 + 序列化结果) =================
// 覆盖 object/array/string/number/bool/null; \uXXXX 只近似处理。
struct JNode {
  enum Type { kNull, kBool, kNum, kStr, kArr, kObj };
  Type type = kNull;
  bool b = false;
  double n = 0;
  std::string s;
  std::vector<JNode> arr;
  std::vector<std::pair<std::string, JNode>> obj;

  const JNode* Get(const std::string& key) const;
  std::string StrOf(const std::string& key, const std::string& def = "") const;
};

JNode ParseJson(const char* text);
std::string ToJson(const JNode& v);

JNode MakeStr(const std::string& s);
JNode MakeNum(double d);
JNode MakeBool(bool b);
JNode MakeObj(std::initializer_list<std::pair<std::string, JNode>> items);

// 支持 {width: 640} 或 {width: {ideal: 640}}, 拿不到用 def
int ConstrainInt(const JNode& obj, const char* key, int def);

// 跨 DLL 边界返回 malloc 字符串(配合 webrtc_free_string 释放)
char* StrDup(const std::string& s);

// 通用 base64 编码工具(当前数据通道二进制消息已改指针直传, 不再走 base64)
std::string Base64Encode(const uint8_t* data, size_t len);

}  // namespace webrtc

#endif  // WEBRTC_COMMON_HXX
