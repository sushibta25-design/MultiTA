#pragma once
#include <string>
#include <vector>
namespace tatelex {
static const char32_t *rows[]={U"aáàảãạ",U"ăắằẳẵặ",U"âấầẩẫậ",U"eéèẻẽẹ",U"êếềểễệ",U"iíìỉĩị",U"oóòỏõọ",U"ôốồổỗộ",U"ơớờởỡợ",U"uúùủũụ",U"ưứừửữự",U"yýỳỷỹỵ",U"AÁÀẢÃẠ",U"ĂẮẰẲẴẶ",U"ÂẤẦẨẪẬ",U"EÉÈẺẼẸ",U"ÊẾỀỂỄỆ",U"IÍÌỈĨỊ",U"OÓÒỎÕỌ",U"ÔỐỒỔỖỘ",U"ƠỚỜỞỠỢ",U"UÚÙỦŨỤ",U"ƯỨỪỬỮỰ",U"YÝỲỶỸỴ"};
static int row(char32_t c) { for(int r=0;r<24;r++) for(int t=0;t<6;t++) if(rows[r][t]==c) return r; return -1; }
static int tone(char32_t c) { int r=row(c); if(r<0) return 0; for(int t=0;t<6;t++) if(rows[r][t]==c) return t; return 0; }
static char32_t lower(char32_t c) { int r=row(c); if(r>=0) return rows[r%12][tone(c)]; if(c>=U'A' && c<=U'Z') return c+32; return c==U'Đ'?U'đ':c; }
static bool letter(char32_t c) { return row(c)>=0 || (lower(c)>=U'a' && lower(c)<=U'z') || lower(c)==U'đ'; }
static void shape(std::u32string &s,size_t i,int r) { int old=row(s[i]); s[i]=rows[r+(old>=12?12:0)][tone(s[i])]; }
static std::vector<size_t> vowels(const std::u32string &s) {
    std::vector<size_t> v;
    for(size_t i=0;i<s.size();i++) if(row(s[i])>=0) v.push_back(i);
    if(v.size()>1 && v[0]==1 && ((lower(s[0])==U'q' && row(s[1])%12==9) || (lower(s[0])==U'g' && row(s[1])%12==5))) v.erase(v.begin());
    return v;
}
static void placeTone(std::u32string &s,int t) {
    auto v=vowels(s); if(v.empty()) return;
    size_t dest=v[0];
    for(auto i:v) { int r=row(s[i]); s[i]=rows[r][0]; }
    bool special=false;
    for(auto i:v) { int r=row(s[i])%12; if(r==1 || r==2 || r==4 || r==7 || r==8 || r==10) { dest=i; special=true; } }
    if(!special) {
        if(v.size()>=3) dest=v[v.size()-2];
        else if(v.size()==2) dest=v.back()+1<s.size()?v.back():v.front();
    }
    s[dest]=rows[row(s[dest])][t];
}
// Incremental composition against the actual word at the caret, not a shadow
// buffer. Cursor movement, deletion, and replacement therefore cannot desync it.
static std::u32string append(std::u32string s,char32_t key) {
    char32_t k=lower(key); int existing=0;
    for(auto c:s) if(tone(c)) existing=tone(c);
    const std::u32string toneKeys=U"sfrxj";
    auto tp=toneKeys.find(k); auto v=vowels(s);
    if(tp!=std::u32string::npos && !v.empty()) {
        int t=(int)tp+1;
        placeTone(s,existing==t?0:t);
        if(existing==t) s+=key; // ass -> as: escape a literal Telex key
        return s;
    }
    if(k==U'z' && existing) { placeTone(s,0); return s; }
    if(k==U'd') for(size_t n=s.size();n>0;n--) {
        size_t i=n-1; char32_t c=lower(s[i]);
        if(c==U'd') { s[i]=s[i]==U'D'?U'Đ':U'đ'; return s; }
        if(c==U'đ') { s[i]=s[i]==U'Đ'?U'D':U'd'; s+=key; return s; }
    }
    if(k==U'a' || k==U'e' || k==U'o') for(size_t n=s.size();n>0;n--) {
        size_t i=n-1; int r=row(s[i]); if(r<0) continue; int b=r%12;
        int plain=k==U'a'?0:k==U'e'?3:6, shaped=k==U'a'?2:k==U'e'?4:7;
        if(b==plain) { shape(s,i,shaped); placeTone(s,existing); return s; }
        if(b==shaped) { shape(s,i,plain); s+=key; placeTone(s,existing); return s; }
        break;
    }
    if(k==U'w' && !v.empty()) {
        for(size_t n=v.size();n>0;n--) {
            size_t i=v[n-1]; int b=row(s[i])%12;
            if(b==6 || b==8) {
                bool pair=n>=2 && v[n-2]+1==i && (row(s[v[n-2]])%12==9 || row(s[v[n-2]])%12==10);
                bool undo=b==8 && (!pair || row(s[v[n-2]])%12==10);
                shape(s,i,undo?6:8); if(pair) shape(s,v[n-2],undo?9:10);
                if(undo) s+=key;
                placeTone(s,existing); return s;
            }
            if(b==0 || b==1 || b==9 || b==10) {
                bool undo=b==1 || b==10; shape(s,i,b==0?1:b==1?0:b==9?10:9);
                if(undo) s+=key;
                placeTone(s,existing); return s;
            }
        }
    }
    s+=key;
    if(existing && letter(key)) placeTone(s,existing);
    return s;
}
}
