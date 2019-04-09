const path = require('path');
const fs = require('fs');
const matchAll = require("match-all");


const fileContent = fs.readFileSync('resources/AtomicCrosschainTransactionCenter.sol', 'utf8').toString();

function checkVisibility(){
	const reVisibility = /function\s+(\w*)\s*\([\w\s,\[\]]*(?:string\s|bytes\s|\w+\[\d*\]\s)[\w\s,\[\]]*\)\s*(?!view|pure)?[\w\s]*public(?!\s*view|\s*pure)\s*\S*\{/g;
	return matchAll(fileContent, reVisibility).toArray();
}

let found = checkVisibility()
console.log(found)

found.forEach(element => {
	var reOccurence = new RegExp('(?<noCap>event\\s+'+element+'\\s*\\(|emit\\s+'+element+'\\s*\\(|function\\s+'+element+'\\s*\\(|\\.'+element+'\\s*\\(|'+element+'\\.)|(?<Cap>'+element+'\\s*\\(|super\\.'+element+'\\s*\\()', "gm");
	let multipleMatch = matchAll(fileContent, reOccurence)

	let object;
	while(object = (multipleMatch.nextRaw() || {})["groups"]){
		
		if (object.Cap) {
			console.log("Nope, not optimizable "+ object.Cap)
		}
		if (object.noCap) {
			console.log("Potentially be optimizable " + object.noCap)
		}
	}

});