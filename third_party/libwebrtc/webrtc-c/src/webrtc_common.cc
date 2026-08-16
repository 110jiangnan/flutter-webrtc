#include "webrtc_common.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace webrtc {

// ================= JNode 访问器 =================

const JNode* JNode::Get(const std::string& key) const {
  if (type != kObj) return nullptr;
  for (auto& kv : obj)
    if (kv.first == key) return &kv.second;
  return nullptr;
}

std::string JNode::StrOf(const std::string& key, const std::string& def) const {
  const JNode* v = Get(key);
  return v && v->type == kStr ? v->s : def;
}

// ================= JSON 解析(内部递归下降) =================

namespace {

class JParser {
 public:
  explicit JParser(const char* text) : p_(text ? text : "") {}
  JNode Parse() {
    JNode v;
    if (!ParseValue(v)) v = JNode{};
    return v;
  }

 private:
  const char* p_;

  void SkipWs() {
    while (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r') ++p_;
  }
  bool ParseValue(JNode& v) {
    SkipWs();
    switch (*p_) {
      case '{': return ParseObject(v);
      case '[': return ParseArray(v);
      case '"': return ParseString(v);
      case 't': return ParseLiteral(v, "true", JNode::kBool, true);
      case 'f': return ParseLiteral(v, "false", JNode::kBool, false);
      case 'n': return ParseLiteral(v, "null", JNode::kNull, false);
      default: return ParseNumber(v);
    }
  }
  bool ParseLiteral(JNode& v, const char* lit, JNode::Type t, bool b) {
    for (const char* q = lit; *q; ++q, ++p_)
      if (*p_ != *q) return false;
    v.type = t;
    v.b = b;
    return true;
  }
  bool ParseString(JNode& v) {
    if (*p_++ != '"') return false;
    v.type = JNode::kStr;
    while (*p_ && *p_ != '"') {
      if (*p_ == '\\' && p_[1]) {
        ++p_;
        switch (*p_) {
          case '"': v.s += '"'; break;
          case '\\': v.s += '\\'; break;
          case '/': v.s += '/'; break;
          case 'n': v.s += '\n'; break;
          case 't': v.s += '\t'; break;
          case 'r': v.s += '\r'; break;
          case 'b': v.s += '\b'; break;
          case 'f': v.s += '\f'; break;
          case 'u':
            if (p_[1] && p_[2] && p_[3] && p_[4]) {
              int code = 0;
              for (int i = 1; i <= 4; ++i) {
                char c = p_[i];
                code = code * 16 + (c >= '0' && c <= '9' ? c - '0'
                                    : c >= 'a' && c <= 'f' ? c - 'a' + 10
                                    : c >= 'A' && c <= 'F' ? c - 'A' + 10
                                                            : 0);
              }
              v.s += static_cast<char>(code);  // 近似, 非 ASCII 会被截断
              p_ += 4;
            }
            break;
          default: v.s += *p_; break;
        }
        ++p_;
      } else {
        v.s += *p_++;
      }
    }
    return *p_++ == '"';
  }
  bool ParseNumber(JNode& v) {
    const char* start = p_;
    while ((*p_ >= '0' && *p_ <= '9') || *p_ == '-' || *p_ == '+' ||
           *p_ == '.' || *p_ == 'e' || *p_ == 'E')
      ++p_;
    if (p_ == start) return false;
    v.type = JNode::kNum;
    v.n = strtod(std::string(start, p_ - start).c_str(), nullptr);
    return true;
  }
  bool ParseObject(JNode& v) {
    v.type = JNode::kObj;
    ++p_;
    SkipWs();
    if (*p_ == '}') { ++p_; return true; }
    while (*p_) {
      SkipWs();
      JNode key;
      if (!ParseString(key)) return false;
      SkipWs();
      if (*p_++ != ':') return false;
      JNode val;
      if (!ParseValue(val)) return false;
      v.obj.emplace_back(std::move(key.s), std::move(val));
      SkipWs();
      if (*p_ == ',') { ++p_; continue; }
      return *p_++ == '}';
    }
    return false;
  }
  bool ParseArray(JNode& v) {
    v.type = JNode::kArr;
    ++p_;
    SkipWs();
    if (*p_ == ']') { ++p_; return true; }
    while (*p_) {
      JNode val;
      if (!ParseValue(val)) return false;
      v.arr.push_back(std::move(val));
      SkipWs();
      if (*p_ == ',') { ++p_; continue; }
      return *p_++ == ']';
    }
    return false;
  }
};

}  // namespace

JNode ParseJson(const char* text) { return JParser(text).Parse(); }

// ================= JSON 序列化 =================

std::string EscapeJson(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

std::string ToJson(const JNode& v) {
  switch (v.type) {
    case JNode::kNull: return "null";
    case JNode::kBool: return v.b ? "true" : "false";
    case JNode::kNum: {
      char buf[32];
      snprintf(buf, sizeof(buf), "%g", v.n);
      return buf;
    }
    case JNode::kStr: return "\"" + EscapeJson(v.s) + "\"";
    case JNode::kArr: {
      std::string out = "[";
      for (size_t i = 0; i < v.arr.size(); ++i) {
        if (i) out += ",";
        out += ToJson(v.arr[i]);
      }
      return out + "]";
    }
    case JNode::kObj: {
      std::string out = "{";
      for (size_t i = 0; i < v.obj.size(); ++i) {
        if (i) out += ",";
        out += "\"" + EscapeJson(v.obj[i].first) + "\":" + ToJson(v.obj[i].second);
      }
      return out + "}";
    }
  }
  return "null";
}

// ================= 构造/小工具 =================

JNode MakeStr(const std::string& s) {
  JNode n;
  n.type = JNode::kStr;
  n.s = s;
  return n;
}
JNode MakeNum(double d) {
  JNode n;
  n.type = JNode::kNum;
  n.n = d;
  return n;
}
JNode MakeBool(bool b) {
  JNode n;
  n.type = JNode::kBool;
  n.b = b;
  return n;
}
JNode MakeObj(std::initializer_list<std::pair<std::string, JNode>> items) {
  JNode n;
  n.type = JNode::kObj;
  for (auto& kv : items) n.obj.push_back(kv);
  return n;
}

int ConstrainInt(const JNode& obj, const char* key, int def) {
  const JNode* v = obj.Get(key);
  if (!v) return def;
  if (v->type == JNode::kNum) return static_cast<int>(v->n);
  if (v->type == JNode::kObj) {
    const JNode* ideal = v->Get("ideal");
    if (ideal && ideal->type == JNode::kNum) return static_cast<int>(ideal->n);
  }
  return def;
}

char* StrDup(const std::string& s) {
  char* p = static_cast<char*>(malloc(s.size() + 1));
  if (!p) return nullptr;
  memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

std::string Base64Encode(const uint8_t* data, size_t len) {
  static const char kTable[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((len + 2) / 3 * 4);
  size_t i = 0;
  while (i + 3 <= len) {
    uint32_t v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    out += kTable[(v >> 18) & 0x3F];
    out += kTable[(v >> 12) & 0x3F];
    out += kTable[(v >> 6) & 0x3F];
    out += kTable[v & 0x3F];
    i += 3;
  }
  if (i + 1 == len) {
    uint32_t v = data[i] << 16;
    out += kTable[(v >> 18) & 0x3F];
    out += kTable[(v >> 12) & 0x3F];
    out += "==";
  } else if (i + 2 == len) {
    uint32_t v = (data[i] << 16) | (data[i + 1] << 8);
    out += kTable[(v >> 18) & 0x3F];
    out += kTable[(v >> 12) & 0x3F];
    out += kTable[(v >> 6) & 0x3F];
    out += '=';
  }
  return out;
}

}  // namespace webrtc
