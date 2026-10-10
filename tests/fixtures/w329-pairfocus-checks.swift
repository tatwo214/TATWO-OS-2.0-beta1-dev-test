import Foundation
import JavaScriptCore

// Execute the shipped native predicate, with attributes read from the unchanged gateway.
// No network, CEF profile, real account, pairing code, or field contents.
// INSERT predicate
// INSERT gateway attributes
let context = JSContext()!
var passes = 0
context.evaluateScript("""
    var rect=[20,20,200,40], hasFocus=true, hitMatches=true;
    function reset() {
      var attributes=\(attributes);
      var field=Object.assign({localName:'input',type:'text',isConnected:true,disabled:false,readOnly:false,
        form:{},matches:()=>false,getAttribute:()=>'',
        getBoundingClientRect:()=>({x:20,y:20,width:200,height:40})},attributes);
      document.activeElement=field; hasFocus=true; hitMatches=true;
    }
    var document={hasFocus:()=>hasFocus,elementFromPoint:()=>hitMatches?document.activeElement:{}};
    reset();
    var focus=\(predicate);
    """)
func check(_ script: String, _ expected: Bool, _ label: String) {
    let result = context.evaluateScript(script)!
    precondition(context.exception == nil, "JavaScript exception: " + label)
    precondition(result.toBool() == expected, label)
    passes += 1
}
check("focus(rect,true)", true, "gateway pairing input accepted")
check("focus(rect)", false, "generic default rejects gateway one-time-code")
check("focus(rect,false)", false, "explicit generic rejects gateway one-time-code")
for mutation in [
    "document.activeElement.type='password'",
    "document.activeElement.type='hidden'",
    "document.activeElement.id='other'",
    "document.activeElement.name='other'",
    "document.activeElement.autocomplete='off'",
    "document.activeElement.form=null",
    "document.activeElement.localName='textarea'",
    "document.activeElement.disabled=true",
    "document.activeElement.readOnly=true",
    "document.activeElement.isConnected=false",
    "document.activeElement=null",
    "hasFocus=false",
    "hitMatches=false"
] {
    check("reset();" + mutation + ";focus(rect,true)", false, mutation)
}
for badRect in ["[21,20,200,40]", "[20,21,200,40]", "[20,20,201,40]", "[20,20,200,41]",
                "[0,0,0,0]", "[20,20,200,0]", "[NaN,20,200,40]", "[20,20,Infinity,40]"] {
    check("reset();focus(\(badRect),true)", false, "pairing rect " + badRect)
}
check("reset();focus([20.9,20.9,200.9,40.9],true)", true, "rect tolerance below one")
for hint in ["password", "one-time-code", "otp", "cc-number", "credit", "card.number", "security.code", "token"] {
    check("reset();document.activeElement.autocomplete='\(hint)';focus(rect,false)", false, "generic hint " + hint)
}
check("reset();document.activeElement.autocomplete='off';focus(rect,false)", true, "generic text remains accepted")
print("W329 SWIFT NATIVE FOCUS SUMMARY passes=\(passes) failures=0")
