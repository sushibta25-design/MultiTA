#include "../TATelex.hpp"
#include <iostream>
#include <cassert>
using namespace tatelex;
static std::u32string type(const std::u32string &keys) {
    std::u32string result;
    for(auto c:keys) {
        if(!letter(c)) { result+=c; continue; }
        size_t start=result.size(); while(start && letter(result[start-1])) --start;
        result=result.substr(0,start)+append(result.substr(start),c);
    }
    return result;
}
int main() {
    const std::pair<std::u32string,std::u32string> cases[]={
        {U"tieengs Vieetj",U"tiếng Việt"},{U"ddia chi",U"đia chi"},
        {U"ddiaj chir",U"địa chỉ"},{U"dduowngf",U"đường"},
        {U"Dduwowngf",U"Đường"},{U"Nguyeenx Traix",U"Nguyễn Trãi"},
        {U"Hoof Chis Minh",U"Hồ Chí Minh"},{U"quaanj",U"quận"},
        {U"huyeenf",U"huyền"},{U"nghieeng",U"nghiêng"},
        {U"hoaf",U"hòa"},{U"hoafn",U"hoàn"},{U"thuys",U"thúy"},
        {U"quys",U"quý"},{U"giaf",U"già"},{U"gias",U"giá"},
        {U"aw aa ee oo ow uw dd",U"ă â ê ô ơ ư đ"},
        {U"as af ar ax aj",U"á à ả ã ạ"},{U"ass",U"as"},
        {U"aaa",U"aa"},{U"ddd",U"dd"},{U"asz",U"a"},
        {U"nguwowif",U"người"},{U"saigon",U"saigon"},
        {U"TIEENGS VIEETJ",U"TIẾNG VIỆT"},
        {U"a 123 as",U"a 123 á"}
    };
    for(size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        if(type(cases[i].first)!=cases[i].second) { std::cerr<<"Failed case "<<i<<"\n"; return 1; }
    }
    assert(append(U"Việ",U't')==U"Việt"); // backspace then retype
    assert(append(U"đườ",U'f')==U"đươf"); // escaped repeated tone
    std::cout<<"Telex word, case, tone placement, escape, and edit tests passed\n";
}
