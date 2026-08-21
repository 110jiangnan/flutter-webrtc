#include "webrtc_common.h"

#include <cstdlib>
#include <cstring>

#include "parson.h"

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

// ================= JSON 解析/序列化 (基于 parson) =================

namespace {

JNode ParssonToJNode(const JSON_Value* v) {
  JNode node;
  switch (json_value_get_type(v)) {
    case JSONNull:
      break;
    case JSONBoolean:
      node.type = JNode::kBool;
      node.b = json_value_get_boolean(v) != 0;
      break;
    case JSONNumber:
      node.type = JNode::kNum;
      node.n = json_value_get_number(v);
      break;
    case JSONString:
      node.type = JNode::kStr;
      node.s = json_value_get_string(v);
      break;
    case JSONArray: {
      node.type = JNode::kArr;
      JSON_Array* arr = json_value_get_array(v);
      size_t n = json_array_get_count(arr);
      node.arr.reserve(n);
      for (size_t i = 0; i < n; ++i)
        node.arr.push_back(ParssonToJNode(json_array_get_value(arr, i)));
      break;
    }
    case JSONObject: {
      node.type = JNode::kObj;
      JSON_Object* obj = json_value_get_object(v);
      size_t n = json_object_get_count(obj);
      node.obj.reserve(n);
      for (size_t i = 0; i < n; ++i)
        node.obj.emplace_back(json_object_get_name(obj, i),
                              ParssonToJNode(json_object_get_value_at(obj, i)));
      break;
    }
    default:
      break;
  }
  return node;
}

JSON_Value* JNodeToParsson(const JNode& v) {
  switch (v.type) {
    case JNode::kNull:
      return json_value_init_null();
    case JNode::kBool:
      return json_value_init_boolean(v.b ? 1 : 0);
    case JNode::kNum:
      return json_value_init_number(v.n);
    case JNode::kStr:
      return json_value_init_string(v.s.c_str());
    case JNode::kArr: {
      JSON_Value* arr = json_value_init_array();
      JSON_Array* ja = json_value_get_array(arr);
      for (auto& item : v.arr)
        json_array_append_value(ja, JNodeToParsson(item));
      return arr;
    }
    case JNode::kObj: {
      JSON_Value* obj = json_value_init_object();
      JSON_Object* jo = json_value_get_object(obj);
      for (auto& kv : v.obj)
        json_object_set_value(jo, kv.first.c_str(), JNodeToParsson(kv.second));
      return obj;
    }
  }
  return json_value_init_null();
}

}  // namespace

JNode ParseJson(const char* text) {
  static int _ = (json_set_escape_slashes(0), 0);
  if (!text || !*text) return JNode{};
  JSON_Value* root = json_parse_string(text);
  if (!root) return JNode{};
  JNode result = ParssonToJNode(root);
  json_value_free(root);
  return result;
}

std::string ToJson(const JNode& v) {
  JSON_Value* root = JNodeToParsson(v);
  char* s = json_serialize_to_string(root);
  std::string out(s ? s : "null");
  if (s) json_free_serialized_string(s);
  json_value_free(root);
  return out;
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

}  // namespace webrtc
