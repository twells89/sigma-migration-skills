var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __commonJS = (cb, mod) => function __require() {
  return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/util.js
var require_util = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/util.js"(exports) {
    "use strict";
    var nameStartChar = ":A-Za-z_\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD";
    var nameChar = nameStartChar + "\\-.\\d\\u00B7\\u0300-\\u036F\\u203F-\\u2040";
    var nameRegexp = "[" + nameStartChar + "][" + nameChar + "]*";
    var regexName = new RegExp("^" + nameRegexp + "$");
    var getAllMatches = function(string, regex) {
      const matches = [];
      let match = regex.exec(string);
      while (match) {
        const allmatches = [];
        allmatches.startIndex = regex.lastIndex - match[0].length;
        const len = match.length;
        for (let index = 0; index < len; index++) {
          allmatches.push(match[index]);
        }
        matches.push(allmatches);
        match = regex.exec(string);
      }
      return matches;
    };
    var isName = function(string) {
      const match = regexName.exec(string);
      return !(match === null || typeof match === "undefined");
    };
    exports.isExist = function(v) {
      return typeof v !== "undefined";
    };
    exports.isEmptyObject = function(obj) {
      return Object.keys(obj).length === 0;
    };
    exports.merge = function(target, a, arrayMode) {
      if (a) {
        const keys = Object.keys(a);
        const len = keys.length;
        for (let i = 0; i < len; i++) {
          if (arrayMode === "strict") {
            target[keys[i]] = [a[keys[i]]];
          } else {
            target[keys[i]] = a[keys[i]];
          }
        }
      }
    };
    exports.getValue = function(v) {
      if (exports.isExist(v)) {
        return v;
      } else {
        return "";
      }
    };
    var DANGEROUS_PROPERTY_NAMES = [
      // '__proto__',
      // 'constructor',
      // 'prototype',
      "hasOwnProperty",
      "toString",
      "valueOf",
      "__defineGetter__",
      "__defineSetter__",
      "__lookupGetter__",
      "__lookupSetter__"
    ];
    var criticalProperties = ["__proto__", "constructor", "prototype"];
    exports.isName = isName;
    exports.getAllMatches = getAllMatches;
    exports.nameRegexp = nameRegexp;
    exports.DANGEROUS_PROPERTY_NAMES = DANGEROUS_PROPERTY_NAMES;
    exports.criticalProperties = criticalProperties;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/validator.js
var require_validator = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/validator.js"(exports) {
    "use strict";
    var util = require_util();
    var defaultOptions = {
      allowBooleanAttributes: false,
      //A tag can have attributes without any value
      unpairedTags: []
    };
    exports.validate = function(xmlData, options) {
      options = Object.assign({}, defaultOptions, options);
      const tags = [];
      let tagFound = false;
      let reachedRoot = false;
      if (xmlData[0] === "\uFEFF") {
        xmlData = xmlData.substr(1);
      }
      for (let i = 0; i < xmlData.length; i++) {
        if (xmlData[i] === "<" && xmlData[i + 1] === "?") {
          i += 2;
          i = readPI(xmlData, i);
          if (i.err) return i;
        } else if (xmlData[i] === "<") {
          let tagStartPos = i;
          i++;
          if (xmlData[i] === "!") {
            i = readCommentAndCDATA(xmlData, i);
            continue;
          } else {
            let closingTag = false;
            if (xmlData[i] === "/") {
              closingTag = true;
              i++;
            }
            let tagName = "";
            for (; i < xmlData.length && xmlData[i] !== ">" && xmlData[i] !== " " && xmlData[i] !== "	" && xmlData[i] !== "\n" && xmlData[i] !== "\r"; i++) {
              tagName += xmlData[i];
            }
            tagName = tagName.trim();
            if (tagName[tagName.length - 1] === "/") {
              tagName = tagName.substring(0, tagName.length - 1);
              i--;
            }
            if (!validateTagName(tagName)) {
              let msg;
              if (tagName.trim().length === 0) {
                msg = "Invalid space after '<'.";
              } else {
                msg = "Tag '" + tagName + "' is an invalid name.";
              }
              return getErrorObject("InvalidTag", msg, getLineNumberForPosition(xmlData, i));
            }
            const result = readAttributeStr(xmlData, i);
            if (result === false) {
              return getErrorObject("InvalidAttr", "Attributes for '" + tagName + "' have open quote.", getLineNumberForPosition(xmlData, i));
            }
            let attrStr = result.value;
            i = result.index;
            if (attrStr[attrStr.length - 1] === "/") {
              const attrStrStart = i - attrStr.length;
              attrStr = attrStr.substring(0, attrStr.length - 1);
              const isValid = validateAttributeString(attrStr, options);
              if (isValid === true) {
                tagFound = true;
              } else {
                return getErrorObject(isValid.err.code, isValid.err.msg, getLineNumberForPosition(xmlData, attrStrStart + isValid.err.line));
              }
            } else if (closingTag) {
              if (!result.tagClosed) {
                return getErrorObject("InvalidTag", "Closing tag '" + tagName + "' doesn't have proper closing.", getLineNumberForPosition(xmlData, i));
              } else if (attrStr.trim().length > 0) {
                return getErrorObject("InvalidTag", "Closing tag '" + tagName + "' can't have attributes or invalid starting.", getLineNumberForPosition(xmlData, tagStartPos));
              } else if (tags.length === 0) {
                return getErrorObject("InvalidTag", "Closing tag '" + tagName + "' has not been opened.", getLineNumberForPosition(xmlData, tagStartPos));
              } else {
                const otg = tags.pop();
                if (tagName !== otg.tagName) {
                  let openPos = getLineNumberForPosition(xmlData, otg.tagStartPos);
                  return getErrorObject(
                    "InvalidTag",
                    "Expected closing tag '" + otg.tagName + "' (opened in line " + openPos.line + ", col " + openPos.col + ") instead of closing tag '" + tagName + "'.",
                    getLineNumberForPosition(xmlData, tagStartPos)
                  );
                }
                if (tags.length == 0) {
                  reachedRoot = true;
                }
              }
            } else {
              const isValid = validateAttributeString(attrStr, options);
              if (isValid !== true) {
                return getErrorObject(isValid.err.code, isValid.err.msg, getLineNumberForPosition(xmlData, i - attrStr.length + isValid.err.line));
              }
              if (reachedRoot === true) {
                return getErrorObject("InvalidXml", "Multiple possible root nodes found.", getLineNumberForPosition(xmlData, i));
              } else if (options.unpairedTags.indexOf(tagName) !== -1) {
              } else {
                tags.push({ tagName, tagStartPos });
              }
              tagFound = true;
            }
            for (i++; i < xmlData.length; i++) {
              if (xmlData[i] === "<") {
                if (xmlData[i + 1] === "!") {
                  i++;
                  i = readCommentAndCDATA(xmlData, i);
                  continue;
                } else if (xmlData[i + 1] === "?") {
                  i = readPI(xmlData, ++i);
                  if (i.err) return i;
                } else {
                  break;
                }
              } else if (xmlData[i] === "&") {
                const afterAmp = validateAmpersand(xmlData, i);
                if (afterAmp == -1)
                  return getErrorObject("InvalidChar", "char '&' is not expected.", getLineNumberForPosition(xmlData, i));
                i = afterAmp;
              } else {
                if (reachedRoot === true && !isWhiteSpace(xmlData[i])) {
                  return getErrorObject("InvalidXml", "Extra text at the end", getLineNumberForPosition(xmlData, i));
                }
              }
            }
            if (xmlData[i] === "<") {
              i--;
            }
          }
        } else {
          if (isWhiteSpace(xmlData[i])) {
            continue;
          }
          return getErrorObject("InvalidChar", "char '" + xmlData[i] + "' is not expected.", getLineNumberForPosition(xmlData, i));
        }
      }
      if (!tagFound) {
        return getErrorObject("InvalidXml", "Start tag expected.", 1);
      } else if (tags.length == 1) {
        return getErrorObject("InvalidTag", "Unclosed tag '" + tags[0].tagName + "'.", getLineNumberForPosition(xmlData, tags[0].tagStartPos));
      } else if (tags.length > 0) {
        return getErrorObject("InvalidXml", "Invalid '" + JSON.stringify(tags.map((t) => t.tagName), null, 4).replace(/\r?\n/g, "") + "' found.", { line: 1, col: 1 });
      }
      return true;
    };
    function isWhiteSpace(char) {
      return char === " " || char === "	" || char === "\n" || char === "\r";
    }
    function readPI(xmlData, i) {
      const start = i;
      for (; i < xmlData.length; i++) {
        if (xmlData[i] == "?" || xmlData[i] == " ") {
          const tagname = xmlData.substr(start, i - start);
          if (i > 5 && tagname === "xml") {
            return getErrorObject("InvalidXml", "XML declaration allowed only at the start of the document.", getLineNumberForPosition(xmlData, i));
          } else if (xmlData[i] == "?" && xmlData[i + 1] == ">") {
            i++;
            break;
          } else {
            continue;
          }
        }
      }
      return i;
    }
    function readCommentAndCDATA(xmlData, i) {
      if (xmlData.length > i + 5 && xmlData[i + 1] === "-" && xmlData[i + 2] === "-") {
        for (i += 3; i < xmlData.length; i++) {
          if (xmlData[i] === "-" && xmlData[i + 1] === "-" && xmlData[i + 2] === ">") {
            i += 2;
            break;
          }
        }
      } else if (xmlData.length > i + 8 && xmlData[i + 1] === "D" && xmlData[i + 2] === "O" && xmlData[i + 3] === "C" && xmlData[i + 4] === "T" && xmlData[i + 5] === "Y" && xmlData[i + 6] === "P" && xmlData[i + 7] === "E") {
        let angleBracketsCount = 1;
        for (i += 8; i < xmlData.length; i++) {
          if (xmlData[i] === "<") {
            angleBracketsCount++;
          } else if (xmlData[i] === ">") {
            angleBracketsCount--;
            if (angleBracketsCount === 0) {
              break;
            }
          }
        }
      } else if (xmlData.length > i + 9 && xmlData[i + 1] === "[" && xmlData[i + 2] === "C" && xmlData[i + 3] === "D" && xmlData[i + 4] === "A" && xmlData[i + 5] === "T" && xmlData[i + 6] === "A" && xmlData[i + 7] === "[") {
        for (i += 8; i < xmlData.length; i++) {
          if (xmlData[i] === "]" && xmlData[i + 1] === "]" && xmlData[i + 2] === ">") {
            i += 2;
            break;
          }
        }
      }
      return i;
    }
    var doubleQuote = '"';
    var singleQuote = "'";
    function readAttributeStr(xmlData, i) {
      let attrStr = "";
      let startChar = "";
      let tagClosed = false;
      for (; i < xmlData.length; i++) {
        if (xmlData[i] === doubleQuote || xmlData[i] === singleQuote) {
          if (startChar === "") {
            startChar = xmlData[i];
          } else if (startChar !== xmlData[i]) {
          } else {
            startChar = "";
          }
        } else if (xmlData[i] === ">") {
          if (startChar === "") {
            tagClosed = true;
            break;
          }
        }
        attrStr += xmlData[i];
      }
      if (startChar !== "") {
        return false;
      }
      return {
        value: attrStr,
        index: i,
        tagClosed
      };
    }
    var validAttrStrRegxp = new RegExp(`(\\s*)([^\\s=]+)(\\s*=)?(\\s*(['"])(([\\s\\S])*?)\\5)?`, "g");
    function validateAttributeString(attrStr, options) {
      const matches = util.getAllMatches(attrStr, validAttrStrRegxp);
      const attrNames = {};
      for (let i = 0; i < matches.length; i++) {
        if (matches[i][1].length === 0) {
          return getErrorObject("InvalidAttr", "Attribute '" + matches[i][2] + "' has no space in starting.", getPositionFromMatch(matches[i]));
        } else if (matches[i][3] !== void 0 && matches[i][4] === void 0) {
          return getErrorObject("InvalidAttr", "Attribute '" + matches[i][2] + "' is without value.", getPositionFromMatch(matches[i]));
        } else if (matches[i][3] === void 0 && !options.allowBooleanAttributes) {
          return getErrorObject("InvalidAttr", "boolean attribute '" + matches[i][2] + "' is not allowed.", getPositionFromMatch(matches[i]));
        }
        const attrName = matches[i][2];
        if (!validateAttrName(attrName)) {
          return getErrorObject("InvalidAttr", "Attribute '" + attrName + "' is an invalid name.", getPositionFromMatch(matches[i]));
        }
        if (!attrNames.hasOwnProperty(attrName)) {
          attrNames[attrName] = 1;
        } else {
          return getErrorObject("InvalidAttr", "Attribute '" + attrName + "' is repeated.", getPositionFromMatch(matches[i]));
        }
      }
      return true;
    }
    function validateNumberAmpersand(xmlData, i) {
      let re = /\d/;
      if (xmlData[i] === "x") {
        i++;
        re = /[\da-fA-F]/;
      }
      for (; i < xmlData.length; i++) {
        if (xmlData[i] === ";")
          return i;
        if (!xmlData[i].match(re))
          break;
      }
      return -1;
    }
    function validateAmpersand(xmlData, i) {
      i++;
      if (xmlData[i] === ";")
        return -1;
      if (xmlData[i] === "#") {
        i++;
        return validateNumberAmpersand(xmlData, i);
      }
      let count = 0;
      for (; i < xmlData.length; i++, count++) {
        if (xmlData[i].match(/\w/) && count < 20)
          continue;
        if (xmlData[i] === ";")
          break;
        return -1;
      }
      return i;
    }
    function getErrorObject(code, message, lineNumber) {
      return {
        err: {
          code,
          msg: message,
          line: lineNumber.line || lineNumber,
          col: lineNumber.col
        }
      };
    }
    function validateAttrName(attrName) {
      return util.isName(attrName);
    }
    function validateTagName(tagname) {
      return util.isName(tagname);
    }
    function getLineNumberForPosition(xmlData, index) {
      const lines = xmlData.substring(0, index).split(/\r?\n/);
      return {
        line: lines.length,
        // column number is last line's length + 1, because column numbering starts at 1:
        col: lines[lines.length - 1].length + 1
      };
    }
    function getPositionFromMatch(match) {
      return match.startIndex + match[1].length;
    }
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js
var require_OptionsBuilder = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js"(exports) {
    var { DANGEROUS_PROPERTY_NAMES, criticalProperties } = require_util();
    var defaultOnDangerousProperty = (name) => {
      if (DANGEROUS_PROPERTY_NAMES.includes(name)) {
        return "__" + name;
      }
      return name;
    };
    var defaultOptions = {
      preserveOrder: false,
      attributeNamePrefix: "@_",
      attributesGroupName: false,
      textNodeName: "#text",
      ignoreAttributes: true,
      removeNSPrefix: false,
      // remove NS from tag name or attribute name if true
      allowBooleanAttributes: false,
      //a tag can have attributes without any value
      //ignoreRootElement : false,
      parseTagValue: true,
      parseAttributeValue: false,
      trimValues: true,
      //Trim string values of tag and attributes
      cdataPropName: false,
      numberParseOptions: {
        hex: true,
        leadingZeros: true,
        eNotation: true
      },
      tagValueProcessor: function(tagName, val) {
        return val;
      },
      attributeValueProcessor: function(attrName, val) {
        return val;
      },
      stopNodes: [],
      //nested tags will not be parsed even for errors
      alwaysCreateTextNode: false,
      isArray: () => false,
      commentPropName: false,
      unpairedTags: [],
      processEntities: true,
      htmlEntities: false,
      ignoreDeclaration: false,
      ignorePiTags: false,
      transformTagName: false,
      transformAttributeName: false,
      updateTag: function(tagName, jPath, attrs) {
        return tagName;
      },
      // skipEmptyListItem: false
      captureMetaData: false,
      maxNestedTags: 100,
      strictReservedNames: true,
      onDangerousProperty: defaultOnDangerousProperty
    };
    function validatePropertyName(propertyName, optionName) {
      if (typeof propertyName !== "string") {
        return;
      }
      const normalized = propertyName.toLowerCase();
      if (DANGEROUS_PROPERTY_NAMES.some((dangerous) => normalized === dangerous.toLowerCase())) {
        throw new Error(
          `[SECURITY] Invalid ${optionName}: "${propertyName}" is a reserved JavaScript keyword that could cause prototype pollution`
        );
      }
      if (criticalProperties.some((dangerous) => normalized === dangerous.toLowerCase())) {
        throw new Error(
          `[SECURITY] Invalid ${optionName}: "${propertyName}" is a reserved JavaScript keyword that could cause prototype pollution`
        );
      }
    }
    function normalizeProcessEntities(value) {
      if (typeof value === "boolean") {
        return {
          enabled: value,
          // true or false
          maxEntitySize: 1e4,
          maxExpansionDepth: 10,
          maxTotalExpansions: 1e3,
          maxExpandedLength: 1e5,
          allowedTags: null,
          tagFilter: null
        };
      }
      if (typeof value === "object" && value !== null) {
        return {
          enabled: value.enabled !== false,
          maxEntitySize: Math.max(1, value.maxEntitySize ?? 1e4),
          maxExpansionDepth: Math.max(1, value.maxExpansionDepth ?? 1e4),
          maxTotalExpansions: Math.max(1, value.maxTotalExpansions ?? Infinity),
          maxExpandedLength: Math.max(1, value.maxExpandedLength ?? 1e5),
          maxEntityCount: Math.max(1, value.maxEntityCount ?? 1e3),
          allowedTags: value.allowedTags ?? null,
          tagFilter: value.tagFilter ?? null
        };
      }
      return normalizeProcessEntities(true);
    }
    var buildOptions = function(options) {
      const built = Object.assign({}, defaultOptions, options);
      const propertyNameOptions = [
        { value: built.attributeNamePrefix, name: "attributeNamePrefix" },
        { value: built.attributesGroupName, name: "attributesGroupName" },
        { value: built.textNodeName, name: "textNodeName" },
        { value: built.cdataPropName, name: "cdataPropName" },
        { value: built.commentPropName, name: "commentPropName" }
      ];
      for (const { value, name } of propertyNameOptions) {
        if (value) {
          validatePropertyName(value, name);
        }
      }
      if (built.onDangerousProperty === null) {
        built.onDangerousProperty = defaultOnDangerousProperty;
      }
      built.processEntities = normalizeProcessEntities(built.processEntities);
      return built;
    };
    exports.buildOptions = buildOptions;
    exports.defaultOptions = defaultOptions;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/xmlNode.js
var require_xmlNode = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/xmlNode.js"(exports, module) {
    "use strict";
    var XmlNode = class {
      constructor(tagname) {
        this.tagname = tagname;
        this.child = [];
        this[":@"] = {};
      }
      add(key, val) {
        if (key === "__proto__") key = "#__proto__";
        this.child.push({ [key]: val });
      }
      addChild(node) {
        if (node.tagname === "__proto__") node.tagname = "#__proto__";
        if (node[":@"] && Object.keys(node[":@"]).length > 0) {
          this.child.push({ [node.tagname]: node.child, [":@"]: node[":@"] });
        } else {
          this.child.push({ [node.tagname]: node.child });
        }
      }
    };
    module.exports = XmlNode;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js
var require_DocTypeReader = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js"(exports, module) {
    var util = require_util();
    var DocTypeReader = class {
      constructor(options) {
        this.suppressValidationErr = !options;
        this.options = options || {};
      }
      readDocType(xmlData, i) {
        const entities = /* @__PURE__ */ Object.create(null);
        let entityCount = 0;
        if (xmlData[i + 3] === "O" && xmlData[i + 4] === "C" && xmlData[i + 5] === "T" && xmlData[i + 6] === "Y" && xmlData[i + 7] === "P" && xmlData[i + 8] === "E") {
          i = i + 9;
          let angleBracketsCount = 1;
          let hasBody = false, comment = false;
          let exp = "";
          for (; i < xmlData.length; i++) {
            if (xmlData[i] === "<" && !comment) {
              if (hasBody && hasSeq(xmlData, "!ENTITY", i)) {
                i += 7;
                let entityName, val;
                [entityName, val, i] = this.readEntityExp(xmlData, i + 1, this.suppressValidationErr);
                if (val.indexOf("&") === -1) {
                  if (this.options.enabled !== false && this.options.maxEntityCount != null && entityCount >= this.options.maxEntityCount) {
                    throw new Error(
                      `Entity count (${entityCount + 1}) exceeds maximum allowed (${this.options.maxEntityCount})`
                    );
                  }
                  const escaped = entityName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
                  entities[entityName] = {
                    regx: RegExp(`&${escaped};`, "g"),
                    val
                  };
                  entityCount++;
                }
              } else if (hasBody && hasSeq(xmlData, "!ELEMENT", i)) {
                i += 8;
                const { index } = this.readElementExp(xmlData, i + 1);
                i = index;
              } else if (hasBody && hasSeq(xmlData, "!ATTLIST", i)) {
                i += 8;
              } else if (hasBody && hasSeq(xmlData, "!NOTATION", i)) {
                i += 9;
                const { index } = this.readNotationExp(xmlData, i + 1, this.suppressValidationErr);
                i = index;
              } else if (hasSeq(xmlData, "!--", i)) {
                comment = true;
              } else {
                throw new Error(`Invalid DOCTYPE`);
              }
              angleBracketsCount++;
              exp = "";
            } else if (xmlData[i] === ">") {
              if (comment) {
                if (xmlData[i - 1] === "-" && xmlData[i - 2] === "-") {
                  comment = false;
                  angleBracketsCount--;
                }
              } else {
                angleBracketsCount--;
              }
              if (angleBracketsCount === 0) {
                break;
              }
            } else if (xmlData[i] === "[") {
              hasBody = true;
            } else {
              exp += xmlData[i];
            }
          }
          if (angleBracketsCount !== 0) {
            throw new Error(`Unclosed DOCTYPE`);
          }
        } else {
          throw new Error(`Invalid Tag instead of DOCTYPE`);
        }
        return { entities, i };
      }
      readEntityExp(xmlData, i) {
        i = skipWhitespace(xmlData, i);
        let entityName = "";
        while (i < xmlData.length && !/\s/.test(xmlData[i]) && xmlData[i] !== '"' && xmlData[i] !== "'") {
          entityName += xmlData[i];
          i++;
        }
        validateEntityName(entityName);
        i = skipWhitespace(xmlData, i);
        if (!this.suppressValidationErr) {
          if (xmlData.substring(i, i + 6).toUpperCase() === "SYSTEM") {
            throw new Error("External entities are not supported");
          } else if (xmlData[i] === "%") {
            throw new Error("Parameter entities are not supported");
          }
        }
        let entityValue = "";
        [i, entityValue] = this.readIdentifierVal(xmlData, i, "entity");
        if (this.options.enabled !== false && this.options.maxEntitySize != null && entityValue.length > this.options.maxEntitySize) {
          throw new Error(
            `Entity "${entityName}" size (${entityValue.length}) exceeds maximum allowed size (${this.options.maxEntitySize})`
          );
        }
        i--;
        return [entityName, entityValue, i];
      }
      readNotationExp(xmlData, i) {
        i = skipWhitespace(xmlData, i);
        let notationName = "";
        while (i < xmlData.length && !/\s/.test(xmlData[i])) {
          notationName += xmlData[i];
          i++;
        }
        !this.suppressValidationErr && validateEntityName(notationName);
        i = skipWhitespace(xmlData, i);
        const identifierType = xmlData.substring(i, i + 6).toUpperCase();
        if (!this.suppressValidationErr && identifierType !== "SYSTEM" && identifierType !== "PUBLIC") {
          throw new Error(`Expected SYSTEM or PUBLIC, found "${identifierType}"`);
        }
        i += identifierType.length;
        i = skipWhitespace(xmlData, i);
        let publicIdentifier = null;
        let systemIdentifier = null;
        if (identifierType === "PUBLIC") {
          [i, publicIdentifier] = this.readIdentifierVal(xmlData, i, "publicIdentifier");
          i = skipWhitespace(xmlData, i);
          if (xmlData[i] === '"' || xmlData[i] === "'") {
            [i, systemIdentifier] = this.readIdentifierVal(xmlData, i, "systemIdentifier");
          }
        } else if (identifierType === "SYSTEM") {
          [i, systemIdentifier] = this.readIdentifierVal(xmlData, i, "systemIdentifier");
          if (!this.suppressValidationErr && !systemIdentifier) {
            throw new Error("Missing mandatory system identifier for SYSTEM notation");
          }
        }
        return { notationName, publicIdentifier, systemIdentifier, index: --i };
      }
      readIdentifierVal(xmlData, i, type) {
        let identifierVal = "";
        const startChar = xmlData[i];
        if (startChar !== '"' && startChar !== "'") {
          throw new Error(`Expected quoted string, found "${startChar}"`);
        }
        i++;
        while (i < xmlData.length && xmlData[i] !== startChar) {
          identifierVal += xmlData[i];
          i++;
        }
        if (xmlData[i] !== startChar) {
          throw new Error(`Unterminated ${type} value`);
        }
        i++;
        return [i, identifierVal];
      }
      readElementExp(xmlData, i) {
        i = skipWhitespace(xmlData, i);
        let elementName = "";
        while (i < xmlData.length && !/\s/.test(xmlData[i])) {
          elementName += xmlData[i];
          i++;
        }
        if (!this.suppressValidationErr && !util.isName(elementName)) {
          throw new Error(`Invalid element name: "${elementName}"`);
        }
        i = skipWhitespace(xmlData, i);
        let contentModel = "";
        if (xmlData[i] === "E" && hasSeq(xmlData, "MPTY", i)) {
          i += 4;
        } else if (xmlData[i] === "A" && hasSeq(xmlData, "NY", i)) {
          i += 2;
        } else if (xmlData[i] === "(") {
          i++;
          while (i < xmlData.length && xmlData[i] !== ")") {
            contentModel += xmlData[i];
            i++;
          }
          if (xmlData[i] !== ")") {
            throw new Error("Unterminated content model");
          }
        } else if (!this.suppressValidationErr) {
          throw new Error(`Invalid Element Expression, found "${xmlData[i]}"`);
        }
        return {
          elementName,
          contentModel: contentModel.trim(),
          index: i
        };
      }
      readAttlistExp(xmlData, i) {
        i = skipWhitespace(xmlData, i);
        let elementName = "";
        while (i < xmlData.length && !/\s/.test(xmlData[i])) {
          elementName += xmlData[i];
          i++;
        }
        validateEntityName(elementName);
        i = skipWhitespace(xmlData, i);
        let attributeName = "";
        while (i < xmlData.length && !/\s/.test(xmlData[i])) {
          attributeName += xmlData[i];
          i++;
        }
        if (!validateEntityName(attributeName)) {
          throw new Error(`Invalid attribute name: "${attributeName}"`);
        }
        i = skipWhitespace(xmlData, i);
        let attributeType = "";
        if (xmlData.substring(i, i + 8).toUpperCase() === "NOTATION") {
          attributeType = "NOTATION";
          i += 8;
          i = skipWhitespace(xmlData, i);
          if (xmlData[i] !== "(") {
            throw new Error(`Expected '(', found "${xmlData[i]}"`);
          }
          i++;
          let allowedNotations = [];
          while (i < xmlData.length && xmlData[i] !== ")") {
            let notation = "";
            while (i < xmlData.length && xmlData[i] !== "|" && xmlData[i] !== ")") {
              notation += xmlData[i];
              i++;
            }
            notation = notation.trim();
            if (!validateEntityName(notation)) {
              throw new Error(`Invalid notation name: "${notation}"`);
            }
            allowedNotations.push(notation);
            if (xmlData[i] === "|") {
              i++;
              i = skipWhitespace(xmlData, i);
            }
          }
          if (xmlData[i] !== ")") {
            throw new Error("Unterminated list of notations");
          }
          i++;
          attributeType += " (" + allowedNotations.join("|") + ")";
        } else {
          while (i < xmlData.length && !/\s/.test(xmlData[i])) {
            attributeType += xmlData[i];
            i++;
          }
          const validTypes = ["CDATA", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS"];
          if (!this.suppressValidationErr && !validTypes.includes(attributeType.toUpperCase())) {
            throw new Error(`Invalid attribute type: "${attributeType}"`);
          }
        }
        i = skipWhitespace(xmlData, i);
        let defaultValue = "";
        if (xmlData.substring(i, i + 8).toUpperCase() === "#REQUIRED") {
          defaultValue = "#REQUIRED";
          i += 8;
        } else if (xmlData.substring(i, i + 7).toUpperCase() === "#IMPLIED") {
          defaultValue = "#IMPLIED";
          i += 7;
        } else {
          [i, defaultValue] = this.readIdentifierVal(xmlData, i, "ATTLIST");
        }
        return {
          elementName,
          attributeName,
          attributeType,
          defaultValue,
          index: i
        };
      }
    };
    var skipWhitespace = (data, index) => {
      while (index < data.length && /\s/.test(data[index])) {
        index++;
      }
      return index;
    };
    function hasSeq(data, seq, i) {
      for (let j = 0; j < seq.length; j++) {
        if (seq[j] !== data[i + j + 1]) return false;
      }
      return true;
    }
    function validateEntityName(name) {
      if (util.isName(name))
        return name;
      else
        throw new Error(`Invalid entity name ${name}`);
    }
    module.exports = DocTypeReader;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/strnum/strnum.js
var require_strnum = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/strnum/strnum.js"(exports, module) {
    var hexRegex = /^[-+]?0x[a-fA-F0-9]+$/;
    var numRegex = /^([\-\+])?(0*)([0-9]*(\.[0-9]*)?)$/;
    var consider = {
      hex: true,
      // oct: false,
      leadingZeros: true,
      decimalPoint: ".",
      eNotation: true
      //skipLike: /regex/
    };
    function toNumber(str, options = {}) {
      options = Object.assign({}, consider, options);
      if (!str || typeof str !== "string") return str;
      let trimmedStr = str.trim();
      if (options.skipLike !== void 0 && options.skipLike.test(trimmedStr)) return str;
      else if (str === "0") return 0;
      else if (options.hex && hexRegex.test(trimmedStr)) {
        return parse_int(trimmedStr, 16);
      } else if (trimmedStr.search(/[eE]/) !== -1) {
        const notation = trimmedStr.match(/^([-\+])?(0*)([0-9]*(\.[0-9]*)?[eE][-\+]?[0-9]+)$/);
        if (notation) {
          if (options.leadingZeros) {
            trimmedStr = (notation[1] || "") + notation[3];
          } else {
            if (notation[2] === "0" && notation[3][0] === ".") {
            } else {
              return str;
            }
          }
          return options.eNotation ? Number(trimmedStr) : str;
        } else {
          return str;
        }
      } else {
        const match = numRegex.exec(trimmedStr);
        if (match) {
          const sign = match[1];
          const leadingZeros = match[2];
          let numTrimmedByZeros = trimZeros(match[3]);
          if (!options.leadingZeros && leadingZeros.length > 0 && sign && trimmedStr[2] !== ".") return str;
          else if (!options.leadingZeros && leadingZeros.length > 0 && !sign && trimmedStr[1] !== ".") return str;
          else if (options.leadingZeros && leadingZeros === str) return 0;
          else {
            const num = Number(trimmedStr);
            const numStr = "" + num;
            if (numStr.search(/[eE]/) !== -1) {
              if (options.eNotation) return num;
              else return str;
            } else if (trimmedStr.indexOf(".") !== -1) {
              if (numStr === "0" && numTrimmedByZeros === "") return num;
              else if (numStr === numTrimmedByZeros) return num;
              else if (sign && numStr === "-" + numTrimmedByZeros) return num;
              else return str;
            }
            if (leadingZeros) {
              return numTrimmedByZeros === numStr || sign + numTrimmedByZeros === numStr ? num : str;
            } else {
              return trimmedStr === numStr || trimmedStr === sign + numStr ? num : str;
            }
          }
        } else {
          return str;
        }
      }
    }
    function trimZeros(numStr) {
      if (numStr && numStr.indexOf(".") !== -1) {
        numStr = numStr.replace(/0+$/, "");
        if (numStr === ".") numStr = "0";
        else if (numStr[0] === ".") numStr = "0" + numStr;
        else if (numStr[numStr.length - 1] === ".") numStr = numStr.substr(0, numStr.length - 1);
        return numStr;
      }
      return numStr;
    }
    function parse_int(numStr, base) {
      if (parseInt) return parseInt(numStr, base);
      else if (Number.parseInt) return Number.parseInt(numStr, base);
      else if (window && window.parseInt) return window.parseInt(numStr, base);
      else throw new Error("parseInt, Number.parseInt, window.parseInt are not supported");
    }
    module.exports = toNumber;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/ignoreAttributes.js
var require_ignoreAttributes = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/ignoreAttributes.js"(exports, module) {
    function getIgnoreAttributesFn(ignoreAttributes) {
      if (typeof ignoreAttributes === "function") {
        return ignoreAttributes;
      }
      if (Array.isArray(ignoreAttributes)) {
        return (attrName) => {
          for (const pattern of ignoreAttributes) {
            if (typeof pattern === "string" && attrName === pattern) {
              return true;
            }
            if (pattern instanceof RegExp && pattern.test(attrName)) {
              return true;
            }
          }
        };
      }
      return () => false;
    }
    module.exports = getIgnoreAttributesFn;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js
var require_OrderedObjParser = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js"(exports, module) {
    "use strict";
    var util = require_util();
    var xmlNode = require_xmlNode();
    var DocTypeReader = require_DocTypeReader();
    var toNumber = require_strnum();
    var getIgnoreAttributesFn = require_ignoreAttributes();
    var OrderedObjParser = class {
      constructor(options) {
        this.options = options;
        this.currentNode = null;
        this.tagsNodeStack = [];
        this.docTypeEntities = {};
        this.lastEntities = {
          "apos": { regex: /&(apos|#39|#x27);/g, val: "'" },
          "gt": { regex: /&(gt|#62|#x3E);/g, val: ">" },
          "lt": { regex: /&(lt|#60|#x3C);/g, val: "<" },
          "quot": { regex: /&(quot|#34|#x22);/g, val: '"' }
        };
        this.ampEntity = { regex: /&(amp|#38|#x26);/g, val: "&" };
        this.htmlEntities = {
          "space": { regex: /&(nbsp|#160);/g, val: " " },
          // "lt" : { regex: /&(lt|#60);/g, val: "<" },
          // "gt" : { regex: /&(gt|#62);/g, val: ">" },
          // "amp" : { regex: /&(amp|#38);/g, val: "&" },
          // "quot" : { regex: /&(quot|#34);/g, val: "\"" },
          // "apos" : { regex: /&(apos|#39);/g, val: "'" },
          "cent": { regex: /&(cent|#162);/g, val: "\xA2" },
          "pound": { regex: /&(pound|#163);/g, val: "\xA3" },
          "yen": { regex: /&(yen|#165);/g, val: "\xA5" },
          "euro": { regex: /&(euro|#8364);/g, val: "\u20AC" },
          "copyright": { regex: /&(copy|#169);/g, val: "\xA9" },
          "reg": { regex: /&(reg|#174);/g, val: "\xAE" },
          "inr": { regex: /&(inr|#8377);/g, val: "\u20B9" },
          "num_dec": { regex: /&#([0-9]{1,7});/g, val: (_, str) => fromCodePoint(str, 10, "&#") },
          "num_hex": { regex: /&#x([0-9a-fA-F]{1,6});/g, val: (_, str) => fromCodePoint(str, 16, "&#x") }
        };
        this.addExternalEntities = addExternalEntities;
        this.parseXml = parseXml;
        this.parseTextData = parseTextData;
        this.resolveNameSpace = resolveNameSpace;
        this.buildAttributesMap = buildAttributesMap;
        this.isItStopNode = isItStopNode;
        this.replaceEntitiesValue = replaceEntitiesValue;
        this.readStopNodeData = readStopNodeData;
        this.saveTextToParentTag = saveTextToParentTag;
        this.addChild = addChild;
        this.ignoreAttributesFn = getIgnoreAttributesFn(this.options.ignoreAttributes);
        this.entityExpansionCount = 0;
        this.currentExpandedLength = 0;
        if (this.options.stopNodes && this.options.stopNodes.length > 0) {
          this.stopNodesExact = /* @__PURE__ */ new Set();
          this.stopNodesWildcard = /* @__PURE__ */ new Set();
          for (let i = 0; i < this.options.stopNodes.length; i++) {
            const stopNodeExp = this.options.stopNodes[i];
            if (typeof stopNodeExp !== "string") continue;
            if (stopNodeExp.startsWith("*.")) {
              this.stopNodesWildcard.add(stopNodeExp.substring(2));
            } else {
              this.stopNodesExact.add(stopNodeExp);
            }
          }
        }
      }
    };
    function addExternalEntities(externalEntities) {
      const entKeys = Object.keys(externalEntities);
      for (let i = 0; i < entKeys.length; i++) {
        const ent = entKeys[i];
        const escaped = ent.replace(/[.\-+*:]/g, "\\.");
        this.lastEntities[ent] = {
          regex: new RegExp("&" + escaped + ";", "g"),
          val: externalEntities[ent]
        };
      }
    }
    function parseTextData(val, tagName, jPath, dontTrim, hasAttributes, isLeafNode, escapeEntities) {
      if (val !== void 0) {
        if (this.options.trimValues && !dontTrim) {
          val = val.trim();
        }
        if (val.length > 0) {
          if (!escapeEntities) val = this.replaceEntitiesValue(val, tagName, jPath);
          const newval = this.options.tagValueProcessor(tagName, val, jPath, hasAttributes, isLeafNode);
          if (newval === null || newval === void 0) {
            return val;
          } else if (typeof newval !== typeof val || newval !== val) {
            return newval;
          } else if (this.options.trimValues) {
            return parseValue(val, this.options.parseTagValue, this.options.numberParseOptions);
          } else {
            const trimmedVal = val.trim();
            if (trimmedVal === val) {
              return parseValue(val, this.options.parseTagValue, this.options.numberParseOptions);
            } else {
              return val;
            }
          }
        }
      }
    }
    function resolveNameSpace(tagname) {
      if (this.options.removeNSPrefix) {
        const tags = tagname.split(":");
        const prefix = tagname.charAt(0) === "/" ? "/" : "";
        if (tags[0] === "xmlns") {
          return "";
        }
        if (tags.length === 2) {
          tagname = prefix + tags[1];
        }
      }
      return tagname;
    }
    var attrsRegx = new RegExp(`([^\\s=]+)\\s*(=\\s*(['"])([\\s\\S]*?)\\3)?`, "gm");
    function buildAttributesMap(attrStr, jPath, tagName) {
      if (this.options.ignoreAttributes !== true && typeof attrStr === "string") {
        const matches = util.getAllMatches(attrStr, attrsRegx);
        const len = matches.length;
        const attrs = {};
        for (let i = 0; i < len; i++) {
          const attrName = this.resolveNameSpace(matches[i][1]);
          if (this.ignoreAttributesFn(attrName, jPath)) {
            continue;
          }
          let oldVal = matches[i][4];
          let aName = this.options.attributeNamePrefix + attrName;
          if (attrName.length) {
            if (this.options.transformAttributeName) {
              aName = this.options.transformAttributeName(aName);
            }
            aName = sanitizeName(aName, this.options);
            if (oldVal !== void 0) {
              if (this.options.trimValues) {
                oldVal = oldVal.trim();
              }
              oldVal = this.replaceEntitiesValue(oldVal, tagName, jPath);
              const newVal = this.options.attributeValueProcessor(attrName, oldVal, jPath);
              if (newVal === null || newVal === void 0) {
                attrs[aName] = oldVal;
              } else if (typeof newVal !== typeof oldVal || newVal !== oldVal) {
                attrs[aName] = newVal;
              } else {
                attrs[aName] = parseValue(
                  oldVal,
                  this.options.parseAttributeValue,
                  this.options.numberParseOptions
                );
              }
            } else if (this.options.allowBooleanAttributes) {
              attrs[aName] = true;
            }
          }
        }
        if (!Object.keys(attrs).length) {
          return;
        }
        if (this.options.attributesGroupName) {
          const attrCollection = {};
          attrCollection[this.options.attributesGroupName] = attrs;
          return attrCollection;
        }
        return attrs;
      }
    }
    var parseXml = function(xmlData) {
      xmlData = xmlData.replace(/\r\n?/g, "\n");
      const xmlObj = new xmlNode("!xml");
      let currentNode = xmlObj;
      let textData = "";
      let jPath = "";
      this.entityExpansionCount = 0;
      this.currentExpandedLength = 0;
      const docTypeReader = new DocTypeReader(this.options.processEntities);
      for (let i = 0; i < xmlData.length; i++) {
        const ch = xmlData[i];
        if (ch === "<") {
          if (xmlData[i + 1] === "/") {
            const closeIndex = findClosingIndex(xmlData, ">", i, "Closing Tag is not closed.");
            let tagName = xmlData.substring(i + 2, closeIndex).trim();
            if (this.options.removeNSPrefix) {
              const colonIndex = tagName.indexOf(":");
              if (colonIndex !== -1) {
                tagName = tagName.substr(colonIndex + 1);
              }
            }
            if (this.options.transformTagName) {
              tagName = this.options.transformTagName(tagName);
            }
            if (currentNode) {
              textData = this.saveTextToParentTag(textData, currentNode, jPath);
            }
            const lastTagName = jPath.substring(jPath.lastIndexOf(".") + 1);
            if (tagName && this.options.unpairedTags.indexOf(tagName) !== -1) {
              throw new Error(`Unpaired tag can not be used as closing tag: </${tagName}>`);
            }
            let propIndex = 0;
            if (lastTagName && this.options.unpairedTags.indexOf(lastTagName) !== -1) {
              propIndex = jPath.lastIndexOf(".", jPath.lastIndexOf(".") - 1);
              this.tagsNodeStack.pop();
            } else {
              propIndex = jPath.lastIndexOf(".");
            }
            jPath = jPath.substring(0, propIndex);
            currentNode = this.tagsNodeStack.pop();
            textData = "";
            i = closeIndex;
          } else if (xmlData[i + 1] === "?") {
            let tagData = readTagExp(xmlData, i, false, "?>");
            if (!tagData) throw new Error("Pi Tag is not closed.");
            textData = this.saveTextToParentTag(textData, currentNode, jPath);
            if (this.options.ignoreDeclaration && tagData.tagName === "?xml" || this.options.ignorePiTags) {
            } else {
              const childNode = new xmlNode(tagData.tagName);
              childNode.add(this.options.textNodeName, "");
              if (tagData.tagName !== tagData.tagExp && tagData.attrExpPresent) {
                childNode[":@"] = this.buildAttributesMap(tagData.tagExp, jPath, tagData.tagName);
              }
              this.addChild(currentNode, childNode, jPath, i);
            }
            i = tagData.closeIndex + 1;
          } else if (xmlData.substr(i + 1, 3) === "!--") {
            const endIndex = findClosingIndex(xmlData, "-->", i + 4, "Comment is not closed.");
            if (this.options.commentPropName) {
              const comment = xmlData.substring(i + 4, endIndex - 2);
              textData = this.saveTextToParentTag(textData, currentNode, jPath);
              currentNode.add(this.options.commentPropName, [{ [this.options.textNodeName]: comment }]);
            }
            i = endIndex;
          } else if (xmlData.substr(i + 1, 2) === "!D") {
            const result = docTypeReader.readDocType(xmlData, i);
            this.docTypeEntities = result.entities;
            i = result.i;
          } else if (xmlData.substr(i + 1, 2) === "![") {
            const closeIndex = findClosingIndex(xmlData, "]]>", i, "CDATA is not closed.") - 2;
            const tagExp = xmlData.substring(i + 9, closeIndex);
            textData = this.saveTextToParentTag(textData, currentNode, jPath);
            let val = this.parseTextData(tagExp, currentNode.tagname, jPath, true, false, true, true);
            if (val == void 0) val = "";
            if (this.options.cdataPropName) {
              currentNode.add(this.options.cdataPropName, [{ [this.options.textNodeName]: tagExp }]);
            } else {
              currentNode.add(this.options.textNodeName, val);
            }
            i = closeIndex + 2;
          } else {
            let result = readTagExp(xmlData, i, this.options.removeNSPrefix);
            let tagName = result.tagName;
            const rawTagName = result.rawTagName;
            let tagExp = result.tagExp;
            let attrExpPresent = result.attrExpPresent;
            let closeIndex = result.closeIndex;
            if (this.options.transformTagName) {
              const newTagName = this.options.transformTagName(tagName);
              if (tagExp === tagName) {
                tagExp = newTagName;
              }
              tagName = newTagName;
            }
            if (this.options.strictReservedNames && (tagName === this.options.commentPropName || tagName === this.options.cdataPropName || tagName === this.options.textNodeName || tagName === this.options.attributesGroupName)) {
              throw new Error(`Invalid tag name: ${tagName}`);
            }
            if (currentNode && textData) {
              if (currentNode.tagname !== "!xml") {
                textData = this.saveTextToParentTag(textData, currentNode, jPath, false);
              }
            }
            const lastTag = currentNode;
            if (lastTag && this.options.unpairedTags.indexOf(lastTag.tagname) !== -1) {
              currentNode = this.tagsNodeStack.pop();
              jPath = jPath.substring(0, jPath.lastIndexOf("."));
            }
            if (tagName !== xmlObj.tagname) {
              jPath += jPath ? "." + tagName : tagName;
            }
            const startIndex = i;
            if (this.isItStopNode(this.stopNodesExact, this.stopNodesWildcard, jPath, tagName)) {
              let tagContent = "";
              if (tagExp.length > 0 && tagExp.lastIndexOf("/") === tagExp.length - 1) {
                if (tagName[tagName.length - 1] === "/") {
                  tagName = tagName.substr(0, tagName.length - 1);
                  jPath = jPath.substr(0, jPath.length - 1);
                  tagExp = tagName;
                } else {
                  tagExp = tagExp.substr(0, tagExp.length - 1);
                }
                i = result.closeIndex;
              } else if (this.options.unpairedTags.indexOf(tagName) !== -1) {
                i = result.closeIndex;
              } else {
                const result2 = this.readStopNodeData(xmlData, rawTagName, closeIndex + 1);
                if (!result2) throw new Error(`Unexpected end of ${rawTagName}`);
                i = result2.i;
                tagContent = result2.tagContent;
              }
              const childNode = new xmlNode(tagName);
              if (tagName !== tagExp && attrExpPresent) {
                childNode[":@"] = this.buildAttributesMap(tagExp, jPath, tagName);
              }
              if (tagContent) {
                tagContent = this.parseTextData(tagContent, tagName, jPath, true, attrExpPresent, true, true);
              }
              jPath = jPath.substr(0, jPath.lastIndexOf("."));
              childNode.add(this.options.textNodeName, tagContent);
              this.addChild(currentNode, childNode, jPath, startIndex);
            } else {
              if (tagExp.length > 0 && tagExp.lastIndexOf("/") === tagExp.length - 1) {
                if (tagName[tagName.length - 1] === "/") {
                  tagName = tagName.substr(0, tagName.length - 1);
                  jPath = jPath.substr(0, jPath.length - 1);
                  tagExp = tagName;
                } else {
                  tagExp = tagExp.substr(0, tagExp.length - 1);
                }
                if (this.options.transformTagName) {
                  const newTagName = this.options.transformTagName(tagName);
                  if (tagExp === tagName) {
                    tagExp = newTagName;
                  }
                  tagName = newTagName;
                }
                const childNode = new xmlNode(tagName);
                if (tagName !== tagExp && attrExpPresent) {
                  childNode[":@"] = this.buildAttributesMap(tagExp, jPath, tagName);
                }
                this.addChild(currentNode, childNode, jPath, startIndex);
                jPath = jPath.substr(0, jPath.lastIndexOf("."));
              } else if (this.options.unpairedTags.indexOf(tagName) !== -1) {
                const childNode = new xmlNode(tagName);
                if (tagName !== tagExp && attrExpPresent) {
                  childNode[":@"] = this.buildAttributesMap(tagExp, jPath);
                }
                this.addChild(currentNode, childNode, jPath, startIndex);
                jPath = jPath.substr(0, jPath.lastIndexOf("."));
                i = result.closeIndex;
                continue;
              } else {
                const childNode = new xmlNode(tagName);
                if (this.tagsNodeStack.length > this.options.maxNestedTags) {
                  throw new Error("Maximum nested tags exceeded");
                }
                this.tagsNodeStack.push(currentNode);
                if (tagName !== tagExp && attrExpPresent) {
                  childNode[":@"] = this.buildAttributesMap(tagExp, jPath, tagName);
                }
                this.addChild(currentNode, childNode, jPath);
                currentNode = childNode;
              }
              textData = "";
              i = closeIndex;
            }
          }
        } else {
          textData += xmlData[i];
        }
      }
      return xmlObj.child;
    };
    function addChild(currentNode, childNode, jPath, startIndex) {
      if (!this.options.captureMetaData) startIndex = void 0;
      const result = this.options.updateTag(childNode.tagname, jPath, childNode[":@"]);
      if (result === false) {
      } else if (typeof result === "string") {
        childNode.tagname = result;
        currentNode.addChild(childNode, startIndex);
      } else {
        currentNode.addChild(childNode, startIndex);
      }
    }
    var replaceEntitiesValue = function(val, tagName, jPath) {
      if (val.indexOf("&") === -1) {
        return val;
      }
      const entityConfig = this.options.processEntities;
      if (!entityConfig.enabled) {
        return val;
      }
      if (entityConfig.allowedTags) {
        if (!entityConfig.allowedTags.includes(tagName)) {
          return val;
        }
      }
      if (entityConfig.tagFilter) {
        if (!entityConfig.tagFilter(tagName, jPath)) {
          return val;
        }
      }
      for (let entityName in this.docTypeEntities) {
        const entity = this.docTypeEntities[entityName];
        const matches = val.match(entity.regx);
        if (matches) {
          this.entityExpansionCount += matches.length;
          if (entityConfig.maxTotalExpansions && this.entityExpansionCount > entityConfig.maxTotalExpansions) {
            throw new Error(
              `Entity expansion limit exceeded: ${this.entityExpansionCount} > ${entityConfig.maxTotalExpansions}`
            );
          }
          const lengthBefore = val.length;
          val = val.replace(entity.regx, entity.val);
          if (entityConfig.maxExpandedLength) {
            this.currentExpandedLength += val.length - lengthBefore;
            if (this.currentExpandedLength > entityConfig.maxExpandedLength) {
              throw new Error(
                `Total expanded content size exceeded: ${this.currentExpandedLength} > ${entityConfig.maxExpandedLength}`
              );
            }
          }
        }
      }
      if (val.indexOf("&") === -1) return val;
      for (const entityName of Object.keys(this.lastEntities)) {
        const entity = this.lastEntities[entityName];
        const matches = val.match(entity.regex);
        if (matches) {
          this.entityExpansionCount += matches.length;
          if (entityConfig.maxTotalExpansions && this.entityExpansionCount > entityConfig.maxTotalExpansions) {
            throw new Error(
              `Entity expansion limit exceeded: ${this.entityExpansionCount} > ${entityConfig.maxTotalExpansions}`
            );
          }
        }
        val = val.replace(entity.regex, entity.val);
      }
      if (val.indexOf("&") === -1) return val;
      if (this.options.htmlEntities) {
        for (const entityName of Object.keys(this.htmlEntities)) {
          const entity = this.htmlEntities[entityName];
          const matches = val.match(entity.regex);
          if (matches) {
            this.entityExpansionCount += matches.length;
            if (entityConfig.maxTotalExpansions && this.entityExpansionCount > entityConfig.maxTotalExpansions) {
              throw new Error(
                `Entity expansion limit exceeded: ${this.entityExpansionCount} > ${entityConfig.maxTotalExpansions}`
              );
            }
          }
          val = val.replace(entity.regex, entity.val);
        }
      }
      val = val.replace(this.ampEntity.regex, this.ampEntity.val);
      return val;
    };
    function saveTextToParentTag(textData, parentNode, jPath, isLeafNode) {
      if (textData) {
        if (isLeafNode === void 0) isLeafNode = parentNode.child.length === 0;
        textData = this.parseTextData(
          textData,
          parentNode.tagname,
          jPath,
          false,
          parentNode[":@"] ? Object.keys(parentNode[":@"]).length !== 0 : false,
          isLeafNode
        );
        if (textData !== void 0 && textData !== "")
          parentNode.add(this.options.textNodeName, textData);
        textData = "";
      }
      return textData;
    }
    function isItStopNode(stopNodesExact, stopNodesWildcard, jPath, currentTagName) {
      if (stopNodesWildcard && stopNodesWildcard.has(currentTagName)) return true;
      if (stopNodesExact && stopNodesExact.has(jPath)) return true;
      return false;
    }
    function tagExpWithClosingIndex(xmlData, i, closingChar = ">") {
      let attrBoundary;
      let tagExp = "";
      for (let index = i; index < xmlData.length; index++) {
        let ch = xmlData[index];
        if (attrBoundary) {
          if (ch === attrBoundary) attrBoundary = "";
        } else if (ch === '"' || ch === "'") {
          attrBoundary = ch;
        } else if (ch === closingChar[0]) {
          if (closingChar[1]) {
            if (xmlData[index + 1] === closingChar[1]) {
              return {
                data: tagExp,
                index
              };
            }
          } else {
            return {
              data: tagExp,
              index
            };
          }
        } else if (ch === "	") {
          ch = " ";
        }
        tagExp += ch;
      }
    }
    function findClosingIndex(xmlData, str, i, errMsg) {
      const closingIndex = xmlData.indexOf(str, i);
      if (closingIndex === -1) {
        throw new Error(errMsg);
      } else {
        return closingIndex + str.length - 1;
      }
    }
    function readTagExp(xmlData, i, removeNSPrefix, closingChar = ">") {
      const result = tagExpWithClosingIndex(xmlData, i + 1, closingChar);
      if (!result) return;
      let tagExp = result.data;
      const closeIndex = result.index;
      const separatorIndex = tagExp.search(/\s/);
      let tagName = tagExp;
      let attrExpPresent = true;
      if (separatorIndex !== -1) {
        tagName = tagExp.substring(0, separatorIndex);
        tagExp = tagExp.substring(separatorIndex + 1).trimStart();
      }
      const rawTagName = tagName;
      if (removeNSPrefix) {
        const colonIndex = tagName.indexOf(":");
        if (colonIndex !== -1) {
          tagName = tagName.substr(colonIndex + 1);
          attrExpPresent = tagName !== result.data.substr(colonIndex + 1);
        }
      }
      return {
        tagName,
        tagExp,
        closeIndex,
        attrExpPresent,
        rawTagName
      };
    }
    function readStopNodeData(xmlData, tagName, i) {
      const startIndex = i;
      let openTagCount = 1;
      for (; i < xmlData.length; i++) {
        if (xmlData[i] === "<") {
          if (xmlData[i + 1] === "/") {
            const closeIndex = findClosingIndex(xmlData, ">", i, `${tagName} is not closed`);
            let closeTagName = xmlData.substring(i + 2, closeIndex).trim();
            if (closeTagName === tagName) {
              openTagCount--;
              if (openTagCount === 0) {
                return {
                  tagContent: xmlData.substring(startIndex, i),
                  i: closeIndex
                };
              }
            }
            i = closeIndex;
          } else if (xmlData[i + 1] === "?") {
            const closeIndex = findClosingIndex(xmlData, "?>", i + 1, "StopNode is not closed.");
            i = closeIndex;
          } else if (xmlData.substr(i + 1, 3) === "!--") {
            const closeIndex = findClosingIndex(xmlData, "-->", i + 3, "StopNode is not closed.");
            i = closeIndex;
          } else if (xmlData.substr(i + 1, 2) === "![") {
            const closeIndex = findClosingIndex(xmlData, "]]>", i, "StopNode is not closed.") - 2;
            i = closeIndex;
          } else {
            const tagData = readTagExp(xmlData, i, ">");
            if (tagData) {
              const openTagName = tagData && tagData.tagName;
              if (openTagName === tagName && tagData.tagExp[tagData.tagExp.length - 1] !== "/") {
                openTagCount++;
              }
              i = tagData.closeIndex;
            }
          }
        }
      }
    }
    function parseValue(val, shouldParse, options) {
      if (shouldParse && typeof val === "string") {
        const newval = val.trim();
        if (newval === "true") return true;
        else if (newval === "false") return false;
        else return toNumber(val, options);
      } else {
        if (util.isExist(val)) {
          return val;
        } else {
          return "";
        }
      }
    }
    function fromCodePoint(str, base, prefix) {
      const codePoint = Number.parseInt(str, base);
      if (codePoint >= 0 && codePoint <= 1114111) {
        return String.fromCodePoint(codePoint);
      } else {
        return prefix + str + ";";
      }
    }
    function sanitizeName(name, options) {
      if (util.criticalProperties.includes(name)) {
        throw new Error(`[SECURITY] Invalid name: "${name}" is a reserved JavaScript keyword that could cause prototype pollution`);
      } else if (util.DANGEROUS_PROPERTY_NAMES.includes(name)) {
        return options.onDangerousProperty(name);
      }
      return name;
    }
    module.exports = OrderedObjParser;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/node2json.js
var require_node2json = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/node2json.js"(exports) {
    "use strict";
    function prettify(node, options) {
      return compress(node, options);
    }
    function compress(arr, options, jPath) {
      let text;
      const compressedObj = {};
      for (let i = 0; i < arr.length; i++) {
        const tagObj = arr[i];
        const property = propName(tagObj);
        let newJpath = "";
        if (jPath === void 0) newJpath = property;
        else newJpath = jPath + "." + property;
        if (property === options.textNodeName) {
          if (text === void 0) text = tagObj[property];
          else text += "" + tagObj[property];
        } else if (property === void 0) {
          continue;
        } else if (tagObj[property]) {
          let val = compress(tagObj[property], options, newJpath);
          const isLeaf = isLeafTag(val, options);
          if (tagObj[":@"]) {
            assignAttributes(val, tagObj[":@"], newJpath, options);
          } else if (Object.keys(val).length === 1 && val[options.textNodeName] !== void 0 && !options.alwaysCreateTextNode) {
            val = val[options.textNodeName];
          } else if (Object.keys(val).length === 0) {
            if (options.alwaysCreateTextNode) val[options.textNodeName] = "";
            else val = "";
          }
          if (compressedObj[property] !== void 0 && compressedObj.hasOwnProperty(property)) {
            if (!Array.isArray(compressedObj[property])) {
              compressedObj[property] = [compressedObj[property]];
            }
            compressedObj[property].push(val);
          } else {
            if (options.isArray(property, newJpath, isLeaf)) {
              compressedObj[property] = [val];
            } else {
              compressedObj[property] = val;
            }
          }
        }
      }
      if (typeof text === "string") {
        if (text.length > 0) compressedObj[options.textNodeName] = text;
      } else if (text !== void 0) compressedObj[options.textNodeName] = text;
      return compressedObj;
    }
    function propName(obj) {
      const keys = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (key !== ":@") return key;
      }
    }
    function assignAttributes(obj, attrMap, jpath, options) {
      if (attrMap) {
        const keys = Object.keys(attrMap);
        const len = keys.length;
        for (let i = 0; i < len; i++) {
          const atrrName = keys[i];
          if (options.isArray(atrrName, jpath + "." + atrrName, true, true)) {
            obj[atrrName] = [attrMap[atrrName]];
          } else {
            obj[atrrName] = attrMap[atrrName];
          }
        }
      }
    }
    function isLeafTag(obj, options) {
      const { textNodeName } = options;
      const propCount = Object.keys(obj).length;
      if (propCount === 0) {
        return true;
      }
      if (propCount === 1 && (obj[textNodeName] || typeof obj[textNodeName] === "boolean" || obj[textNodeName] === 0)) {
        return true;
      }
      return false;
    }
    exports.prettify = prettify;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/XMLParser.js
var require_XMLParser = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlparser/XMLParser.js"(exports, module) {
    var { buildOptions } = require_OptionsBuilder();
    var OrderedObjParser = require_OrderedObjParser();
    var { prettify } = require_node2json();
    var validator = require_validator();
    var XMLParser2 = class {
      constructor(options) {
        this.externalEntities = {};
        this.options = buildOptions(options);
      }
      /**
       * Parse XML dats to JS object 
       * @param {string|Buffer} xmlData 
       * @param {boolean|Object} validationOption 
       */
      parse(xmlData, validationOption) {
        if (typeof xmlData === "string") {
        } else if (xmlData.toString) {
          xmlData = xmlData.toString();
        } else {
          throw new Error("XML data is accepted in String or Bytes[] form.");
        }
        if (validationOption) {
          if (validationOption === true) validationOption = {};
          const result = validator.validate(xmlData, validationOption);
          if (result !== true) {
            throw Error(`${result.err.msg}:${result.err.line}:${result.err.col}`);
          }
        }
        const orderedObjParser = new OrderedObjParser(this.options);
        orderedObjParser.addExternalEntities(this.externalEntities);
        const orderedResult = orderedObjParser.parseXml(xmlData);
        if (this.options.preserveOrder || orderedResult === void 0) return orderedResult;
        else return prettify(orderedResult, this.options);
      }
      /**
       * Add Entity which is not by default supported by this library
       * @param {string} key 
       * @param {string} value 
       */
      addEntity(key, value) {
        if (value.indexOf("&") !== -1) {
          throw new Error("Entity value can't have '&'");
        } else if (key.indexOf("&") !== -1 || key.indexOf(";") !== -1) {
          throw new Error("An entity must be set without '&' and ';'. Eg. use '#xD' for '&#xD;'");
        } else if (value === "&") {
          throw new Error("An entity with value '&' is not permitted");
        } else {
          this.externalEntities[key] = value;
        }
      }
    };
    module.exports = XMLParser2;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlbuilder/orderedJs2Xml.js
var require_orderedJs2Xml = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlbuilder/orderedJs2Xml.js"(exports, module) {
    var EOL = "\n";
    function toXml(jArray, options) {
      let indentation = "";
      if (options.format && options.indentBy.length > 0) {
        indentation = EOL;
      }
      return arrToStr(jArray, options, "", indentation);
    }
    function arrToStr(arr, options, jPath, indentation) {
      let xmlStr = "";
      let isPreviousElementTag = false;
      if (!Array.isArray(arr)) {
        if (arr !== void 0 && arr !== null) {
          let text = arr.toString();
          text = replaceEntitiesValue(text, options);
          return text;
        }
        return "";
      }
      for (let i = 0; i < arr.length; i++) {
        const tagObj = arr[i];
        const tagName = propName(tagObj);
        if (tagName === void 0) continue;
        let newJPath = "";
        if (jPath.length === 0) newJPath = tagName;
        else newJPath = `${jPath}.${tagName}`;
        if (tagName === options.textNodeName) {
          let tagText = tagObj[tagName];
          if (!isStopNode(newJPath, options)) {
            tagText = options.tagValueProcessor(tagName, tagText);
            tagText = replaceEntitiesValue(tagText, options);
          }
          if (isPreviousElementTag) {
            xmlStr += indentation;
          }
          xmlStr += tagText;
          isPreviousElementTag = false;
          continue;
        } else if (tagName === options.cdataPropName) {
          if (isPreviousElementTag) {
            xmlStr += indentation;
          }
          xmlStr += `<![CDATA[${tagObj[tagName][0][options.textNodeName]}]]>`;
          isPreviousElementTag = false;
          continue;
        } else if (tagName === options.commentPropName) {
          xmlStr += indentation + `<!--${tagObj[tagName][0][options.textNodeName]}-->`;
          isPreviousElementTag = true;
          continue;
        } else if (tagName[0] === "?") {
          const attStr2 = attr_to_str(tagObj[":@"], options);
          const tempInd = tagName === "?xml" ? "" : indentation;
          let piTextNodeName = tagObj[tagName][0][options.textNodeName];
          piTextNodeName = piTextNodeName.length !== 0 ? " " + piTextNodeName : "";
          xmlStr += tempInd + `<${tagName}${piTextNodeName}${attStr2}?>`;
          isPreviousElementTag = true;
          continue;
        }
        let newIdentation = indentation;
        if (newIdentation !== "") {
          newIdentation += options.indentBy;
        }
        const attStr = attr_to_str(tagObj[":@"], options);
        const tagStart = indentation + `<${tagName}${attStr}`;
        const tagValue = arrToStr(tagObj[tagName], options, newJPath, newIdentation);
        if (options.unpairedTags.indexOf(tagName) !== -1) {
          if (options.suppressUnpairedNode) xmlStr += tagStart + ">";
          else xmlStr += tagStart + "/>";
        } else if ((!tagValue || tagValue.length === 0) && options.suppressEmptyNode) {
          xmlStr += tagStart + "/>";
        } else if (tagValue && tagValue.endsWith(">")) {
          xmlStr += tagStart + `>${tagValue}${indentation}</${tagName}>`;
        } else {
          xmlStr += tagStart + ">";
          if (tagValue && indentation !== "" && (tagValue.includes("/>") || tagValue.includes("</"))) {
            xmlStr += indentation + options.indentBy + tagValue + indentation;
          } else {
            xmlStr += tagValue;
          }
          xmlStr += `</${tagName}>`;
        }
        isPreviousElementTag = true;
      }
      return xmlStr;
    }
    function propName(obj) {
      const keys = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (!Object.prototype.hasOwnProperty.call(obj, key)) continue;
        if (key !== ":@") return key;
      }
    }
    function attr_to_str(attrMap, options) {
      let attrStr = "";
      if (attrMap && !options.ignoreAttributes) {
        for (let attr2 in attrMap) {
          if (!Object.prototype.hasOwnProperty.call(attrMap, attr2)) continue;
          let attrVal = options.attributeValueProcessor(attr2, attrMap[attr2]);
          attrVal = replaceEntitiesValue(attrVal, options);
          if (attrVal === true && options.suppressBooleanAttributes) {
            attrStr += ` ${attr2.substr(options.attributeNamePrefix.length)}`;
          } else {
            attrStr += ` ${attr2.substr(options.attributeNamePrefix.length)}="${attrVal}"`;
          }
        }
      }
      return attrStr;
    }
    function isStopNode(jPath, options) {
      jPath = jPath.substr(0, jPath.length - options.textNodeName.length - 1);
      let tagName = jPath.substr(jPath.lastIndexOf(".") + 1);
      for (let index in options.stopNodes) {
        if (options.stopNodes[index] === jPath || options.stopNodes[index] === "*." + tagName) return true;
      }
      return false;
    }
    function replaceEntitiesValue(textValue, options) {
      if (textValue && textValue.length > 0 && options.processEntities) {
        for (let i = 0; i < options.entities.length; i++) {
          const entity = options.entities[i];
          textValue = textValue.replace(entity.regex, entity.val);
        }
      }
      return textValue;
    }
    module.exports = toXml;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlbuilder/json2xml.js
var require_json2xml = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/xmlbuilder/json2xml.js"(exports, module) {
    "use strict";
    var buildFromOrderedJs = require_orderedJs2Xml();
    var getIgnoreAttributesFn = require_ignoreAttributes();
    var defaultOptions = {
      attributeNamePrefix: "@_",
      attributesGroupName: false,
      textNodeName: "#text",
      ignoreAttributes: true,
      cdataPropName: false,
      format: false,
      indentBy: "  ",
      suppressEmptyNode: false,
      suppressUnpairedNode: true,
      suppressBooleanAttributes: true,
      tagValueProcessor: function(key, a) {
        return a;
      },
      attributeValueProcessor: function(attrName, a) {
        return a;
      },
      preserveOrder: false,
      commentPropName: false,
      unpairedTags: [],
      entities: [
        { regex: new RegExp("&", "g"), val: "&amp;" },
        //it must be on top
        { regex: new RegExp(">", "g"), val: "&gt;" },
        { regex: new RegExp("<", "g"), val: "&lt;" },
        { regex: new RegExp("'", "g"), val: "&apos;" },
        { regex: new RegExp('"', "g"), val: "&quot;" }
      ],
      processEntities: true,
      stopNodes: [],
      // transformTagName: false,
      // transformAttributeName: false,
      oneListGroup: false
    };
    function Builder(options) {
      this.options = Object.assign({}, defaultOptions, options);
      if (this.options.ignoreAttributes === true || this.options.attributesGroupName) {
        this.isAttribute = function() {
          return false;
        };
      } else {
        this.ignoreAttributesFn = getIgnoreAttributesFn(this.options.ignoreAttributes);
        this.attrPrefixLen = this.options.attributeNamePrefix.length;
        this.isAttribute = isAttribute;
      }
      this.processTextOrObjNode = processTextOrObjNode;
      if (this.options.format) {
        this.indentate = indentate;
        this.tagEndChar = ">\n";
        this.newLine = "\n";
      } else {
        this.indentate = function() {
          return "";
        };
        this.tagEndChar = ">";
        this.newLine = "";
      }
    }
    Builder.prototype.build = function(jObj) {
      if (this.options.preserveOrder) {
        return buildFromOrderedJs(jObj, this.options);
      } else {
        if (Array.isArray(jObj) && this.options.arrayNodeName && this.options.arrayNodeName.length > 1) {
          jObj = {
            [this.options.arrayNodeName]: jObj
          };
        }
        return this.j2x(jObj, 0, []).val;
      }
    };
    Builder.prototype.j2x = function(jObj, level, ajPath) {
      let attrStr = "";
      let val = "";
      const jPath = ajPath.join(".");
      for (let key in jObj) {
        if (!Object.prototype.hasOwnProperty.call(jObj, key)) continue;
        if (typeof jObj[key] === "undefined") {
          if (this.isAttribute(key)) {
            val += "";
          }
        } else if (jObj[key] === null) {
          if (this.isAttribute(key)) {
            val += "";
          } else if (key === this.options.cdataPropName) {
            val += "";
          } else if (key[0] === "?") {
            val += this.indentate(level) + "<" + key + "?" + this.tagEndChar;
          } else {
            val += this.indentate(level) + "<" + key + "/" + this.tagEndChar;
          }
        } else if (jObj[key] instanceof Date) {
          val += this.buildTextValNode(jObj[key], key, "", level);
        } else if (typeof jObj[key] !== "object") {
          const attr2 = this.isAttribute(key);
          if (attr2 && !this.ignoreAttributesFn(attr2, jPath)) {
            attrStr += this.buildAttrPairStr(attr2, "" + jObj[key]);
          } else if (!attr2) {
            if (key === this.options.textNodeName) {
              let newval = this.options.tagValueProcessor(key, "" + jObj[key]);
              val += this.replaceEntitiesValue(newval);
            } else {
              val += this.buildTextValNode(jObj[key], key, "", level);
            }
          }
        } else if (Array.isArray(jObj[key])) {
          const arrLen = jObj[key].length;
          let listTagVal = "";
          let listTagAttr = "";
          for (let j = 0; j < arrLen; j++) {
            const item = jObj[key][j];
            if (typeof item === "undefined") {
            } else if (item === null) {
              if (key[0] === "?") val += this.indentate(level) + "<" + key + "?" + this.tagEndChar;
              else val += this.indentate(level) + "<" + key + "/" + this.tagEndChar;
            } else if (typeof item === "object") {
              if (this.options.oneListGroup) {
                const result = this.j2x(item, level + 1, ajPath.concat(key));
                listTagVal += result.val;
                if (this.options.attributesGroupName && item.hasOwnProperty(this.options.attributesGroupName)) {
                  listTagAttr += result.attrStr;
                }
              } else {
                listTagVal += this.processTextOrObjNode(item, key, level, ajPath);
              }
            } else {
              if (this.options.oneListGroup) {
                let textValue = this.options.tagValueProcessor(key, item);
                textValue = this.replaceEntitiesValue(textValue);
                listTagVal += textValue;
              } else {
                listTagVal += this.buildTextValNode(item, key, "", level);
              }
            }
          }
          if (this.options.oneListGroup) {
            listTagVal = this.buildObjectNode(listTagVal, key, listTagAttr, level);
          }
          val += listTagVal;
        } else {
          if (this.options.attributesGroupName && key === this.options.attributesGroupName) {
            const Ks = Object.keys(jObj[key]);
            const L = Ks.length;
            for (let j = 0; j < L; j++) {
              attrStr += this.buildAttrPairStr(Ks[j], "" + jObj[key][Ks[j]]);
            }
          } else {
            val += this.processTextOrObjNode(jObj[key], key, level, ajPath);
          }
        }
      }
      return { attrStr, val };
    };
    Builder.prototype.buildAttrPairStr = function(attrName, val) {
      val = this.options.attributeValueProcessor(attrName, "" + val);
      val = this.replaceEntitiesValue(val);
      if (this.options.suppressBooleanAttributes && val === "true") {
        return " " + attrName;
      } else return " " + attrName + '="' + val + '"';
    };
    function processTextOrObjNode(object, key, level, ajPath) {
      const result = this.j2x(object, level + 1, ajPath.concat(key));
      if (object[this.options.textNodeName] !== void 0 && Object.keys(object).length === 1) {
        return this.buildTextValNode(object[this.options.textNodeName], key, result.attrStr, level);
      } else {
        return this.buildObjectNode(result.val, key, result.attrStr, level);
      }
    }
    Builder.prototype.buildObjectNode = function(val, key, attrStr, level) {
      if (val === "") {
        if (key[0] === "?") return this.indentate(level) + "<" + key + attrStr + "?" + this.tagEndChar;
        else {
          return this.indentate(level) + "<" + key + attrStr + this.closeTag(key) + this.tagEndChar;
        }
      } else {
        let tagEndExp = "</" + key + this.tagEndChar;
        let piClosingChar = "";
        if (key[0] === "?") {
          piClosingChar = "?";
          tagEndExp = "";
        }
        if ((attrStr || attrStr === "") && val.indexOf("<") === -1) {
          return this.indentate(level) + "<" + key + attrStr + piClosingChar + ">" + val + tagEndExp;
        } else if (this.options.commentPropName !== false && key === this.options.commentPropName && piClosingChar.length === 0) {
          return this.indentate(level) + `<!--${val}-->` + this.newLine;
        } else {
          return this.indentate(level) + "<" + key + attrStr + piClosingChar + this.tagEndChar + val + this.indentate(level) + tagEndExp;
        }
      }
    };
    Builder.prototype.closeTag = function(key) {
      let closeTag = "";
      if (this.options.unpairedTags.indexOf(key) !== -1) {
        if (!this.options.suppressUnpairedNode) closeTag = "/";
      } else if (this.options.suppressEmptyNode) {
        closeTag = "/";
      } else {
        closeTag = `></${key}`;
      }
      return closeTag;
    };
    Builder.prototype.buildTextValNode = function(val, key, attrStr, level) {
      if (this.options.cdataPropName !== false && key === this.options.cdataPropName) {
        return this.indentate(level) + `<![CDATA[${val}]]>` + this.newLine;
      } else if (this.options.commentPropName !== false && key === this.options.commentPropName) {
        return this.indentate(level) + `<!--${val}-->` + this.newLine;
      } else if (key[0] === "?") {
        return this.indentate(level) + "<" + key + attrStr + "?" + this.tagEndChar;
      } else {
        let textValue = this.options.tagValueProcessor(key, val);
        textValue = this.replaceEntitiesValue(textValue);
        if (textValue === "") {
          return this.indentate(level) + "<" + key + attrStr + this.closeTag(key) + this.tagEndChar;
        } else {
          return this.indentate(level) + "<" + key + attrStr + ">" + textValue + "</" + key + this.tagEndChar;
        }
      }
    };
    Builder.prototype.replaceEntitiesValue = function(textValue) {
      if (textValue && textValue.length > 0 && this.options.processEntities) {
        for (let i = 0; i < this.options.entities.length; i++) {
          const entity = this.options.entities[i];
          textValue = textValue.replace(entity.regex, entity.val);
        }
      }
      return textValue;
    };
    function indentate(level) {
      return this.options.indentBy.repeat(level);
    }
    function isAttribute(name) {
      if (name.startsWith(this.options.attributeNamePrefix) && name !== this.options.textNodeName) {
        return name.substr(this.attrPrefixLen);
      } else {
        return false;
      }
    }
    module.exports = Builder;
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/fxp.js
var require_fxp = __commonJS({
  "../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/node_modules/fast-xml-parser/src/fxp.js"(exports, module) {
    "use strict";
    var validator = require_validator();
    var XMLParser2 = require_XMLParser();
    var XMLBuilder = require_json2xml();
    module.exports = {
      XMLParser: XMLParser2,
      XMLValidator: validator,
      XMLBuilder
    };
  }
});

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/build/tableau.js
var import_fast_xml_parser = __toESM(require_fxp(), 1);

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/build/sigma-ids.js
var SIGMA_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
var _usedIds = /* @__PURE__ */ new Set();
var SIGMA_LOWERCASE_WORDS = /* @__PURE__ */ new Set([
  "a",
  "an",
  "the",
  "and",
  "but",
  "or",
  "for",
  "nor",
  "so",
  "yet",
  "at",
  "by",
  "in",
  "of",
  "on",
  "to",
  "up",
  "as",
  "into",
  "via",
  "per"
]);
function resetIds() {
  _usedIds.clear();
}
function sigmaShortId(len = 10) {
  let id;
  do {
    id = Array.from({ length: len }, () => SIGMA_CHARS[Math.floor(Math.random() * SIGMA_CHARS.length)]).join("");
  } while (_usedIds.has(id));
  _usedIds.add(id);
  return id;
}
function sigmaInodeId(identifier) {
  return `inode-${sigmaShortId(22)}/${identifier.toUpperCase()}`;
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s]+/).filter(Boolean);
  return words.map((w, i) => i === 0 || !SIGMA_LOWERCASE_WORDS.has(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w).join(" ");
}
function formatFromMask(mask) {
  if (!mask || typeof mask !== "string")
    return null;
  const s = mask.trim();
  if (!s || /general|date|time|@|yy|dd/i.test(s))
    return null;
  const decM = s.match(/\.([0#]+)/);
  const decimals = decM ? decM[1].length : 0;
  const isPercent = /%/.test(s);
  const isCurrency = /[$£€¥]/.test(s);
  if (isPercent)
    return { kind: "number", formatString: `,.${decimals}%` };
  if (isCurrency)
    return { kind: "number", formatString: `$,.${decimals}f`, currencySymbol: "$" };
  if (/[0#]/.test(s))
    return { kind: "number", formatString: `,.${decimals}f` };
  return null;
}
function inferSigmaFormat(formula, displayName, sourceMask) {
  const fromMask = formatFromMask(sourceMask);
  if (fromMask)
    return fromMask;
  if (!formula)
    return null;
  const f = formula.trim();
  const n = (displayName || "").toLowerCase();
  const alreadyPctScale = /\*\s*100\b/.test(f);
  if (alreadyPctScale && /\b(rate|margin|pct|percent|ratio|share|mix)\b|%/.test(n)) {
    return { kind: "number", formatString: ",.2f", suffix: "%" };
  }
  const currencyWord = /\b(revenue|sales|profit|cost|spend|amount|discounts?|price|value|aov|arpu)\b/;
  const ratio = f.match(/^([A-Za-z]+)\s*\(([^)]*)\)\s*\/\s*([A-Za-z]+)\s*\(([^)]*)\)$/);
  if (ratio) {
    const [, numFn, numArg, denFn, denArg] = ratio;
    const isCount = (fn) => /^Count/i.test(fn);
    const numIsCurrency = currencyWord.test(numArg.toLowerCase());
    const nameSaysPct = /\b(rate|margin|pct|percent|ratio|share|mix)\b|%/.test(n);
    if (nameSaysPct || isCount(numFn) && isCount(denFn)) {
      return { kind: "number", formatString: ",.2%" };
    }
    if (numIsCurrency) {
      return { kind: "number", formatString: "$,.2f", currencySymbol: "$" };
    }
    return { kind: "number", formatString: ",.2f" };
  }
  if (/\b(rate|margin|pct|percent|ratio|share|mix)\b|%/.test(n)) {
    return { kind: "number", formatString: ",.2%" };
  }
  if (currencyWord.test(n)) {
    return { kind: "number", formatString: "$,.2f", currencySymbol: "$" };
  }
  if (/^Count(?:Distinct|If|DistinctIf)?\s*\(/.test(f)) {
    return { kind: "number", formatString: ",.0f" };
  }
  return null;
}
var DATA_MODEL_SCHEMA_SUMMARY = `
Sigma Data Model JSON top-level structure:
{
  "name": "Model Name",
  "pages": [{ "id": "pageId", "name": "Page 1", "elements": [...] }]
}

Element types: warehouse-table, custom-sql (kind:"sql"), join, union, control.
Columns: { "id": "inode-xxx/COL", "formula": "[TABLE/Display Name]" }
Calculated columns: { "id": "shortId", "formula": "[Price] - [Cost]", "name": "Profit" }
Metrics: { "id": "shortId", "formula": "Sum([Revenue])", "name": "Total Revenue" }
Relationships: { "id": "shortId", "targetElementId": "...", "keys": [{ "sourceColumnId": "...", "targetColumnId": "..." }] }

Cross-element Reference (accessing related dimension columns via relationships):
  [SOURCE_TABLE/REL_NAME/Column Display Name]
  REL_NAME is the relationship's "name" field (= target table name uppercase by convention).
  Example: DateDiff("day", [ORDER_FACT/PROMO_DIM/Start Date], [ORDER_FACT/PROMO_DIM/End Date])
  \u26A0 The dash-link form [SRC/FK_COL - link/Field] does NOT work via the API \u2014 use REL_NAME.

Conditional Aggregate Syntax:
  CountIf(condition) \u2014 condition only, NO field argument
  SumIf(field, condition) \u2014 FIELD FIRST, condition second
  AvgIf/MaxIf/MinIf/CountDistinctIf \u2014 all FIELD FIRST
  For booleans: always use [Column] = True, never bare [Column]

Groupings (for LOD / different aggregation levels):
  "groupings": [{ "id": "gId", "groupBy": ["colId1"], "calculations": ["calcId1"] }]
  Array order = nesting hierarchy. Use child elements for LOD patterns.
`.trim();
function _securityElementName(el) {
  if (el?.name)
    return el.name;
  const path = el?.source?.path;
  return path && path.length ? String(path[path.length - 1]) : void 0;
}
function makeRlsSecurity(opts) {
  const attrs = [...opts.formula.matchAll(/CurrentUserAttributeText\(\s*"([^"]+)"/g)].map((m) => m[1]);
  const teams = [...opts.formula.matchAll(/CurrentUserInTeam\(\s*"([^"]+)"/g)].map((m) => m[1]);
  const usesEmail = /\bCurrentUserEmail\(/.test(opts.formula);
  const provision = [
    attrs.length ? `provision/assign Sigma user attribute(s): ${[...new Set(attrs)].join(", ")}` : "",
    teams.length ? `create Sigma team(s) + membership: ${[...new Set(teams)].join(", ")}` : "",
    usesEmail && !attrs.length && !teams.length ? "uses CurrentUserEmail() \u2014 no provisioning needed" : ""
  ].filter(Boolean).join("; ");
  return {
    kind: "rls",
    source: opts.source,
    elementId: opts.element.id,
    elementName: _securityElementName(opts.element),
    rls: {
      name: opts.name,
      formula: opts.formula,
      userAttributes: attrs.length ? [...new Set(attrs)] : void 0,
      teams: teams.length ? [...new Set(teams)] : void 0,
      usesCurrentUserEmail: usesEmail || void 0
    },
    note: `Fail-closed RLS (boolean calc + element filter, only True rows). ${provision || "review"}. The skill provisions then applies \u2014 the converter does NOT inject it.`
  };
}
function buildDerivedElements(elements) {
  const derived = [];
  for (const srcEl of elements) {
    if (!srcEl.relationships?.length)
      continue;
    if (srcEl.source?.kind !== "warehouse-table")
      continue;
    const srcPath = srcEl.source.path || [];
    const srcTableName = srcPath[srcPath.length - 1] || "";
    const baseName = srcEl.name || srcTableName;
    const derivedName = `${srcEl.name || sigmaDisplayName(srcTableName)} View`;
    const viewCols = [];
    const viewOrder = [];
    for (const col of srcEl.columns || []) {
      if (!col.formula || col.formula.startsWith("/*"))
        continue;
      let dispName;
      const fm = col.formula.match(/^\[([^\/\]]+)\/([^\]]+)\]$/);
      if (fm)
        dispName = fm[2];
      else if (col.name)
        dispName = String(col.name);
      if (!dispName)
        continue;
      if (dispName.includes("/"))
        continue;
      const cId = sigmaShortId();
      viewCols.push({ id: cId, formula: `[${baseName}/${dispName}]` });
      viewOrder.push(cId);
    }
    for (const rel of srcEl.relationships) {
      if (!rel.name)
        continue;
      const tgtEl = elements.find((e) => e.id === rel.targetElementId);
      if (!tgtEl || tgtEl.source?.kind !== "warehouse-table" && tgtEl.source?.kind !== "sql")
        continue;
      const tgtKeyIds = new Set((rel.keys || []).map((k) => k.targetColumnId));
      for (const col of tgtEl.columns || []) {
        if (tgtKeyIds.has(col.id))
          continue;
        if (!col.formula || col.formula.startsWith("/*"))
          continue;
        let dispName;
        if (col.name) {
          dispName = String(col.name);
        } else {
          const fm = col.formula.match(/^\[([^\]]+)\]$/);
          if (fm) {
            const inner = fm[1];
            const s = inner.indexOf("/");
            dispName = s >= 0 ? inner.slice(s + 1) : inner;
          }
        }
        if (!dispName)
          continue;
        if (dispName.includes("/"))
          continue;
        const cId = sigmaShortId();
        viewCols.push({ id: cId, formula: `[${baseName}/${rel.name}/${dispName}]` });
        viewOrder.push(cId);
      }
    }
    if (viewCols.length > 0) {
      derived.push({
        id: sigmaShortId(),
        kind: "table",
        name: derivedName,
        source: { kind: "table", elementId: srcEl.id },
        columns: viewCols,
        order: viewOrder
      });
    }
  }
  return derived;
}

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/build/formulas.js
function decodeXmlEntities(s) {
  if (!s || s.indexOf("&") === -1)
    return s;
  return s.replace(/&#x([0-9a-fA-F]+);/g, (_m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (_m, d) => String.fromCodePoint(parseInt(d, 10))).replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}
function stripLineComments(s) {
  if (!s || s.indexOf("//") === -1)
    return s;
  let out = "", inS = false, inD = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inS) {
      out += c;
      if (c === "'")
        inS = false;
      continue;
    }
    if (inD) {
      out += c;
      if (c === '"')
        inD = false;
      continue;
    }
    if (c === "'") {
      inS = true;
      out += c;
      continue;
    }
    if (c === '"') {
      inD = true;
      out += c;
      continue;
    }
    if (c === "/" && s[i + 1] === "/") {
      while (i < s.length && s[i] !== "\n")
        i++;
      if (i < s.length)
        out += "\n";
      continue;
    }
    out += c;
  }
  return out;
}
function tableauInToSigma(formula) {
  const re = /(\[[^\]]+\]|[A-Za-z_][\w]*)\s+(not\s+)?in\s*\(/gi;
  let f = formula, guard = 0;
  for (let m = re.exec(f); m && guard < 200; m = re.exec(f), guard++) {
    const operand = m[1];
    const isNot = !!m[2];
    const open = m.index + m[0].length - 1;
    let depth = 0, close = -1;
    for (let i = open; i < f.length; i++) {
      if (f[i] === "(")
        depth++;
      else if (f[i] === ")") {
        depth--;
        if (depth === 0) {
          close = i;
          break;
        }
      }
    }
    if (close === -1)
      break;
    const inner = f.slice(open + 1, close);
    const parts = [];
    let buf = "", d = 0, sq = false, dq = false;
    for (const ch of inner) {
      if (sq) {
        buf += ch;
        if (ch === "'")
          sq = false;
        continue;
      }
      if (dq) {
        buf += ch;
        if (ch === '"')
          dq = false;
        continue;
      }
      if (ch === "'") {
        sq = true;
        buf += ch;
        continue;
      }
      if (ch === '"') {
        dq = true;
        buf += ch;
        continue;
      }
      if (ch === "(") {
        d++;
        buf += ch;
        continue;
      }
      if (ch === ")") {
        d--;
        buf += ch;
        continue;
      }
      if (ch === "," && d === 0) {
        parts.push(buf.trim());
        buf = "";
        continue;
      }
      buf += ch;
    }
    if (buf.trim())
      parts.push(buf.trim());
    if (!parts.length)
      continue;
    const op = isNot ? "<>" : "=";
    const join = isNot ? " and " : " or ";
    const chain = "(" + parts.map((p) => `${operand} ${op} ${p}`).join(join) + ")";
    f = f.slice(0, m.index) + chain + f.slice(close + 1);
    re.lastIndex = m.index + chain.length;
  }
  return f;
}
var _TEXT_FN_RE = /(?:Coalesce|Concat|Text|Left|Right|Mid|Substring|Substr|Upper|Lower|Trim|Replace|MonthName|WeekdayName|DateName|Proper)$/i;
function _isTextOperand(op, isTextRef) {
  let s = op.trim();
  while (/^\(.*\)$/s.test(s)) {
    let depth = 0, ok = true;
    for (let i = 0; i < s.length; i++) {
      if (s[i] === "(")
        depth++;
      else if (s[i] === ")") {
        depth--;
        if (depth === 0 && i < s.length - 1) {
          ok = false;
          break;
        }
      }
    }
    if (!ok || depth !== 0)
      break;
    s = s.slice(1, -1).trim();
  }
  if (!s)
    return false;
  if (/^"(?:[^"\\]|\\.)*"$/.test(s) || /^'(?:[^'\\]|\\.)*'$/.test(s))
    return true;
  const ref = s.match(/^\[([^\]\/]+)\]$/);
  if (ref)
    return isTextRef ? isTextRef(ref[1]) : false;
  const fn = s.match(/^([A-Za-z_]+)\s*\(.*\)$/s);
  if (fn && _TEXT_FN_RE.test(fn[1]))
    return true;
  return false;
}
function tableauTextConcatToSigma(formula, isTextRef) {
  if (!formula || formula.indexOf("+") === -1)
    return formula;
  const grab = (s, i, dir) => {
    let j = i;
    while (j >= 0 && j < s.length && /\s/.test(s[j]))
      j += dir;
    if (j < 0 || j >= s.length)
      return "";
    const close = dir < 0 ? s[j] : "";
    if (dir < 0 && (close === ")" || close === "]")) {
      const open = close === ")" ? "(" : "[", cl = close;
      let depth = 0, k2 = j;
      for (; k2 >= 0; k2--) {
        if (s[k2] === cl)
          depth++;
        else if (s[k2] === open) {
          depth--;
          if (depth === 0)
            break;
        }
      }
      let f2 = k2;
      while (f2 - 1 >= 0 && /[A-Za-z0-9_]/.test(s[f2 - 1]))
        f2--;
      return s.slice(f2, j + 1);
    }
    if (dir > 0 && (s[j] === "(" || s[j] === "[")) {
      const open = s[j], cl = open === "(" ? ")" : "]";
      let depth = 0, k2 = j;
      for (; k2 < s.length; k2++) {
        if (s[k2] === open)
          depth++;
        else if (s[k2] === cl) {
          depth--;
          if (depth === 0)
            break;
        }
      }
      return s.slice(j, k2 + 1);
    }
    if (s[j] === '"' || s[j] === "'") {
      const q = s[j];
      let k2 = j + dir;
      while (k2 >= 0 && k2 < s.length && s[k2] !== q)
        k2 += dir;
      return dir < 0 ? s.slice(k2, j + 1) : s.slice(j, k2 + 1);
    }
    let k = j;
    while (k >= 0 && k < s.length && /[A-Za-z0-9_.]/.test(s[k]))
      k += dir;
    return dir < 0 ? s.slice(k + 1, j + 1) : s.slice(j, k);
  };
  let f = formula, changed = true, guard = 0;
  while (changed && guard++ < 500) {
    changed = false;
    for (let i = 0; i < f.length; i++) {
      if (f[i] !== "+")
        continue;
      const left = grab(f, i - 1, -1), right = grab(f, i + 1, 1);
      if (_isTextOperand(left, isTextRef) || _isTextOperand(right, isTextRef)) {
        f = f.slice(0, i) + "&" + f.slice(i + 1);
        changed = true;
        break;
      }
    }
  }
  return f;
}
function tableauParamSwitchToSigma(formula, controlId, warnings) {
  const f = decodeXmlEntities(stripLineComments(formula)).trim();
  const head = f.match(/^case\s+\[Parameters?\]\s*\.\s*\[([^\]]+)\]\s+([\s\S]*?)\s*end\s*$/i);
  if (!head)
    return null;
  const paramName = head[1];
  const body = head[2];
  const cases = [];
  const pairRe = /\bwhen\s+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s+then\s+([\s\S]*?)(?=\s*\bwhen\b|\s*\belse\b|$)/gi;
  let m;
  while (m = pairRe.exec(body)) {
    const whenVal = m[1].slice(1, -1).replace(/\\(.)/g, "$1");
    const thenSig = tableauFormulaToSigma(m[2].trim(), warnings);
    cases.push({ when: whenVal, then: thenSig });
  }
  if (!cases.length)
    return null;
  const elseM = body.match(/\belse\s+([\s\S]*?)$/i);
  const elseExpr = elseM ? tableauFormulaToSigma(elseM[1].trim(), warnings) : null;
  const parts = cases.map((c) => `"${c.when}", ${c.then}`).join(", ");
  const switchFormula = `Switch([${controlId}], ${parts}${elseExpr ? `, ${elseExpr}` : ""})`;
  return { paramName, controlId, cases, elseExpr, switchFormula };
}
var TABLEAU_FUNC_MAP = {
  "AVG": "Avg",
  "MAX": "Max",
  "MIN": "Min",
  "MEDIAN": "Median",
  "SUM": "Sum",
  "ABS": "Abs",
  "CEILING": "Ceiling",
  "FLOOR": "Floor",
  "ROUND": "Round",
  "SQRT": "Sqrt",
  "POWER": "Power",
  // scalar math (verified resolve in Sigma 2026-06-15; Tableau LOG default base 10 == Sigma Log default base 10)
  "LN": "Ln",
  "LOG": "Log",
  "EXP": "Exp",
  "MOD": "Mod",
  "SIGN": "Sign",
  "PI": "Pi",
  "STR": "Text",
  "INT": "Int",
  "FLOAT": "Number",
  "LEN": "Len",
  "UPPER": "Upper",
  "LOWER": "Lower",
  "TRIM": "Trim",
  "LTRIM": "Ltrim",
  "RTRIM": "Rtrim",
  "LEFT": "Left",
  "RIGHT": "Right",
  "MID": "Mid",
  "REPLACE": "Replace",
  "CONTAINS": "Contains",
  "STARTSWITH": "StartsWith",
  "ENDSWITH": "EndsWith",
  "FIND": "Find",
  "TODAY": "Today",
  "NOW": "Now",
  "YEAR": "Year",
  "MONTH": "Month",
  "DAY": "Day",
  "HOUR": "Hour",
  "MINUTE": "Minute",
  "SECOND": "Second",
  "WEEK": "Week",
  "QUARTER": "Quarter",
  "DATE": "Date",
  "DATETIME": "Datetime",
  "MAKEDATE": "MakeDate",
  // regex (same arg order as Tableau)
  "REGEXP_EXTRACT": "RegexpExtract",
  "REGEXP_REPLACE": "RegexpReplace",
  "REGEXP_MATCH": "RegexpMatch",
  // statistical aggregates (sample variants direct; STDEVP handled above)
  "STDEV": "StdDev",
  "VAR": "Variance",
  "VARP": "VariancePop",
  "PERCENTILE": "PercentileCont",
  "CORR": "Corr",
  // string split — both 1-indexed, negatives count from the right
  "SPLIT": "SplitPart"
};
var SIGMA_CHART_ONLY_WINDOW_RE = /\b(?:Cumulative(?:Sum|Avg|Min|Max|Count)|Moving(?:Sum|Avg|Min|Max|Count|StdDev)|RankDense|RankPercentile|Rank|PercentOfTotal|RowNumber|Lag|Lead)\s*\(/;
var TABLEAU_TABLE_CALC_TOKEN_RE = /\b(?:WINDOW_[A-Z]+|RUNNING_[A-Z]+|LOOKUP|PREVIOUS_VALUE|RANK(?:_[A-Z]+)?|INDEX|SIZE|TOTAL|FIRST|LAST)\s*\(/;
var TABLEAU_TABLE_CALC_TOKEN_CI_RE = /\b(?:WINDOW_[A-Za-z]+|RUNNING_[A-Za-z]+|PREVIOUS_VALUE)\s*\(/i;
var TABLEAU_LOD_LEFTOVER_RE = /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i;
function formulaHasUntranslatableFragment(f) {
  if (!f)
    return false;
  if (TABLEAU_LOD_LEFTOVER_RE.test(f) || TABLEAU_TABLE_CALC_TOKEN_RE.test(f) || TABLEAU_TABLE_CALC_TOKEN_CI_RE.test(f) || /\/\*\s*(?:LOD|table calc|no Sigma equivalent)/.test(f))
    return true;
  const masked = f.replace(/"[^"]*"|'[^']*'|\[[^\]]*\]/g, " ");
  return /\b(?:then|end|when)\b/i.test(masked);
}
var _TC_AGG_MAP = {
  SUM: "Sum",
  AVG: "Avg",
  MIN: "Min",
  MAX: "Max",
  COUNT: "Count",
  COUNTD: "CountDistinct",
  MEDIAN: "Median",
  STDEV: "StdDev",
  VAR: "Variance"
};
var _TC_COL = "(\\[[^\\]]+\\]|[A-Za-z_][A-Za-z0-9_]*)";
var _TC_AGG = "(SUM|AVG|MIN|MAX|COUNT|COUNTD|MEDIAN|STDEV|VAR)";
var _TC_AGG_EXPR = `${_TC_AGG}\\s*\\(\\s*${_TC_COL}\\s*\\)`;
function _tcCol(raw) {
  const name = raw.replace(/^\[|\]$/g, "");
  if (/^[A-Z][A-Z0-9_]{2,}$/.test(name))
    return "[" + sigmaDisplayName(name) + "]";
  return "[" + name + "]";
}
function _tcAgg(aggFunc, colRaw) {
  const fn = _TC_AGG_MAP[aggFunc.toUpperCase()] || "Sum";
  return `${fn}(${_tcCol(colRaw)})`;
}
function _tcSameRef(a, b) {
  const norm = (s) => s.replace(/^\[|\]$/g, "").replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
  return norm(a) === norm(b);
}
function tableauWindowUntranslatable(formula) {
  const m = (formula || "").match(/\b(WINDOW_MEDIAN|WINDOW_PERCENTILE|WINDOW_CORR|WINDOW_COVARP?|WINDOW_VARP?|WINDOW_STDEVP|PREVIOUS_VALUE|SIZE)\s*\(/i);
  return m ? m[1].toUpperCase() : null;
}
function tableauWindowToSigmaChart(formula) {
  const f = (formula || "").trim();
  if (!f || tableauWindowUntranslatable(f))
    return null;
  let m;
  m = f.match(new RegExp(`^${_TC_AGG_EXPR}\\s*\\/\\s*(?:TOTAL|WINDOW_SUM)\\s*\\(\\s*${_TC_AGG_EXPR}\\s*\\)$`, "i"));
  if (m && m[1].toUpperCase() === m[3].toUpperCase() && _tcSameRef(m[2], m[4])) {
    return { formula: `PercentOfTotal(${_tcAgg(m[1], m[2])}, "grand_total")`, kind: "percent-of-total" };
  }
  m = f.match(new RegExp(`^RUNNING_SUM\\s*\\(\\s*${_TC_AGG_EXPR}\\s*\\)\\s*\\/\\s*(?:TOTAL|WINDOW_SUM)\\s*\\(\\s*${_TC_AGG_EXPR}\\s*\\)$`, "i"));
  if (m && m[1].toUpperCase() === m[3].toUpperCase() && _tcSameRef(m[2], m[4])) {
    return { formula: `CumulativeSum(PercentOfTotal(${_tcAgg(m[1], m[2])}, "grand_total"))`, kind: "cumulative" };
  }
  m = f.match(new RegExp(`^RUNNING_(SUM|AVG|MIN|MAX|COUNT)\\s*\\(\\s*${_TC_AGG_EXPR}\\s*\\)$`, "i"));
  if (m) {
    const fn = "Cumulative" + m[1].charAt(0).toUpperCase() + m[1].slice(1).toLowerCase();
    return { formula: `${fn}(${_tcAgg(m[2], m[3])})`, kind: "cumulative" };
  }
  m = f.match(new RegExp(`^RUNNING_(SUM|AVG|MIN|MAX|COUNT)\\s*\\(\\s*${_TC_COL}\\s*\\)$`, "i"));
  if (m) {
    const fn = "Cumulative" + m[1].charAt(0).toUpperCase() + m[1].slice(1).toLowerCase();
    return { formula: `${fn}(${_tcAgg(m[1], m[2])})`, kind: "cumulative" };
  }
  m = f.match(new RegExp(`^WINDOW_(SUM|AVG|MIN|MAX|STDEV)\\s*\\(\\s*${_TC_AGG_EXPR}\\s*,\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)$`, "i"));
  if (m) {
    const back = parseInt(m[4], 10);
    const fwd = parseInt(m[5], 10);
    if (back <= 0 && fwd >= 0) {
      const movMap = {
        SUM: "MovingSum",
        AVG: "MovingAvg",
        MIN: "MovingMin",
        MAX: "MovingMax",
        STDEV: "MovingStdDev"
      };
      const fn = movMap[m[1].toUpperCase()];
      const args = fwd === 0 ? `${-back}` : `${-back}, ${fwd}`;
      return { formula: `${fn}(${_tcAgg(m[2], m[3])}, ${args})`, kind: "moving" };
    }
    return null;
  }
  m = f.match(new RegExp(`^(RANK|RANK_DENSE|RANK_PERCENTILE|RANK_UNIQUE)\\s*\\(\\s*${_TC_AGG_EXPR}\\s*(?:,\\s*['"]?(asc|desc)['"]?\\s*)?\\)$`, "i"));
  if (m) {
    const fnMap = {
      RANK: "Rank",
      RANK_DENSE: "RankDense",
      RANK_PERCENTILE: "RankPercentile",
      RANK_UNIQUE: "Rank"
    };
    const fn = fnMap[m[1].toUpperCase()];
    const dir = (m[4] || "desc").toLowerCase();
    const unique = m[1].toUpperCase() === "RANK_UNIQUE";
    return {
      formula: `${fn}(${_tcAgg(m[2], m[3])}, "${dir}")`,
      kind: "rank",
      ...unique ? { verify: true, note: "RANK_UNIQUE breaks ties arbitrarily; Sigma Rank assigns equal ranks to ties \u2014 verify against Tableau." } : {}
    };
  }
  if (/^INDEX\s*\(\s*\)$/i.test(f))
    return { formula: "RowNumber()", kind: "index" };
  m = f.match(new RegExp(`^LOOKUP\\s*\\(\\s*${_TC_AGG_EXPR}\\s*,\\s*(-?\\d+)\\s*\\)$`, "i"));
  if (m) {
    const off = parseInt(m[3], 10);
    const agg = _tcAgg(m[1], m[2]);
    if (off === 0)
      return { formula: agg, kind: "lag", note: "LOOKUP(expr, 0) is the identity \u2014 no window function needed." };
    return off < 0 ? { formula: `Lag(${agg}, ${-off})`, kind: "lag" } : { formula: `Lead(${agg}, ${off})`, kind: "lead" };
  }
  return null;
}
function tableauIfToSigma(f) {
  return f.replace(/\bIF\b([\s\S]+?)\bEND\b/gi, (match) => {
    let inner = match.replace(/^\s*IF\s*/i, "").replace(/\s*END\s*$/i, "");
    const elseIdx = inner.search(/\bELSE\b(?!\s*IF\b)/i);
    let elseVal = "null";
    if (elseIdx >= 0) {
      elseVal = tableauFormulaToSigma(inner.slice(elseIdx).replace(/^\s*ELSE\s*/i, "").trim());
      inner = inner.slice(0, elseIdx);
    }
    const parts = inner.split(/\bELSEIF\b/i);
    let result = elseVal;
    for (let i = parts.length - 1; i >= 0; i--) {
      const thenParts = parts[i].split(/\bTHEN\b/i);
      if (thenParts.length < 2)
        continue;
      const cond = tableauFormulaToSigma(thenParts[0].trim());
      const val = tableauFormulaToSigma(thenParts[1].trim());
      result = "If(" + cond + ", " + val + ", " + result + ")";
    }
    return result;
  });
}
function tableauCaseToSigma(f) {
  return f.replace(/\bCASE\b([\s\S]+?)\bEND\b/gi, (match, body) => {
    const elseIdx = body.search(/\bELSE\b/i);
    let elseVal = "null";
    let whenBody = body;
    if (elseIdx >= 0) {
      elseVal = tableauFormulaToSigma(body.slice(elseIdx).replace(/^\s*ELSE\s*/i, "").trim());
      whenBody = body.slice(0, elseIdx);
    }
    const fieldMatch = whenBody.match(/^([\s\S]*?)\bWHEN\b/i);
    const field = fieldMatch ? tableauFormulaToSigma(fieldMatch[1].trim()) : "[?]";
    const pairs = whenBody.replace(/^[\s\S]*?\bWHEN\b/i, "").split(/\bWHEN\b/i).filter(Boolean);
    let result = elseVal;
    for (let i = pairs.length - 1; i >= 0; i--) {
      const thenParts = pairs[i].split(/\bTHEN\b/i);
      if (thenParts.length < 2)
        continue;
      result = "If(" + field + " = " + tableauFormulaToSigma(thenParts[0].trim()) + ", " + tableauFormulaToSigma(thenParts[1].trim()) + ", " + result + ")";
    }
    return result;
  });
}
function tableauFormulaToSigma(formula, warnings) {
  if (!formula || !formula.trim())
    return "";
  let f = stripLineComments(decodeXmlEntities(formula)).trim();
  if (/^\s*\{/.test(f)) {
    if (warnings)
      warnings.push("\u26A0 LOD expression not converted: " + f.slice(0, 60));
    return "/* LOD: " + f.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
  }
  {
    const winChart = tableauWindowToSigmaChart(f);
    if (winChart) {
      if (warnings)
        warnings.push(`\u2139 Table calc \u2192 ${winChart.formula} \u2014 CHART/grouped-element context ONLY: place in a grouped workbook element (group by the viz dimensions); window functions silently error in data-model calc columns and workbook master calc columns.` + (winChart.note ? " " + winChart.note : ""));
      return winChart.formula;
    }
    const untrans = tableauWindowUntranslatable(f);
    if (untrans) {
      if (warnings)
        warnings.push(`\u26A0 Table calculation NOT converted \u2014 ${untrans}() has no Sigma equivalent. Untranslated fragment: ${f.slice(0, 120)}`);
      return "/* table calc: " + f.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
    }
    if (/^(WINDOW_|RUNNING_|FIRST\(|LAST\(|INDEX\(|RANK\b|RANK_|LOOKUP\(|TOTAL\s*\()/i.test(f)) {
      const gt = f.match(/^WINDOW_SUM\s*\(\s*(SUM|COUNT|AVG|MIN|MAX)\s*\(\s*(\[[^\]]+\])\s*\)\s*\)$/i);
      if (gt) {
        const aggMap = { SUM: "Sum", COUNT: "Count", AVG: "Avg", MIN: "Min", MAX: "Max" };
        return "GrandTotal(" + (aggMap[gt[1].toUpperCase()] || gt[1]) + "(" + gt[2] + "))";
      }
      if (warnings)
        warnings.push(`\u26A0 Table calculation not converted. Untranslated fragment: ${f.slice(0, 120)}`);
      return "/* table calc: " + f.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
    }
  }
  if (/\bCOVARP?\s*\(/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 COVAR/COVARP has no Sigma equivalent \u2014 not converted. Fragment: ${f.slice(0, 120)}`);
    return "/* no Sigma equivalent: " + f.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
  }
  f = f.replace(/\bZN\s*\(([^)]+)\)/gi, "Coalesce($1, 0)");
  f = f.replace(/\bIFNULL\s*\(/gi, "Coalesce(").replace(/\bIFERROR\s*\(/gi, "Coalesce(");
  f = f.replace(/\bISNULL\s*\(/gi, "IsNull(");
  f = f.replace(/\bCOUNT\s*\(([^)]+)\)/gi, (m, arg) => "CountIf(IsNotNull(" + arg.trim() + "))");
  f = f.replace(/\bCOUNTD\s*\(/gi, "CountDistinct(");
  f = f.replace(/\bATTR\s*\(([^)]+)\)/gi, "$1");
  f = tableauInToSigma(f);
  f = tableauIfToSigma(f);
  f = f.replace(/\bIIF\s*\(/gi, "If(");
  f = tableauCaseToSigma(f);
  f = f.replace(/\bDATEPART\s*\(\s*'(\w+)'\s*,\s*([^)]+)\)/gi, (m, part, dateArg) => {
    const partMap = {
      year: "Year",
      month: "Month",
      day: "Day",
      hour: "Hour",
      minute: "Minute",
      second: "Second",
      week: "Week",
      quarter: "Quarter",
      dayofweek: "DayOfWeek",
      weekday: "DayOfWeek"
    };
    const fn = partMap[part.toLowerCase()];
    return fn ? fn + "(" + dateArg.trim() + ")" : m;
  });
  f = f.replace(/\bDATENAME\s*\(\s*'(\w+)'\s*,\s*([^,)]+)(?:,[^)]*)?\)/gi, (m, part, dateArg) => {
    const arg = dateArg.trim();
    switch (part.toLowerCase()) {
      case "month":
        return "MonthName(" + arg + ")";
      case "weekday":
      case "dayofweek":
        return "WeekdayName(" + arg + ")";
      case "year":
        return "Text(Year(" + arg + "))";
      case "quarter":
        return "Text(Quarter(" + arg + "))";
      case "day":
        return "Text(Day(" + arg + "))";
      case "week":
        return "Text(Week(" + arg + "))";
      case "hour":
        return "Text(Hour(" + arg + "))";
      case "minute":
        return "Text(Minute(" + arg + "))";
      case "second":
        return "Text(Second(" + arg + "))";
      default:
        return m;
    }
  });
  f = f.replace(/\bDATETRUNC\s*\(\s*'([^']+)'\s*,/gi, 'DateTrunc("$1",');
  f = f.replace(/,\s*["'](?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)["']\s*\)/gi, ")");
  f = f.replace(/\bDATEADD\s*\(\s*'([^']+)'\s*,/gi, 'DateAdd("$1",');
  f = f.replace(/\bDATEDIFF\s*\(\s*'([^']+)'\s*,/gi, 'DateDiff("$1",');
  f = f.replace(/\bSTDEVP\s*\(([^()]+(?:\([^()]*\)[^()]*)*)\)/gi, "Sqrt(VariancePop($1))");
  f = f.replace(/\bDATEPARSE\s*\(\s*('[^']*'|"[^"]*")\s*,\s*([^()]+(?:\([^()]*\)[^()]*)*)\)/gi, (_m, fmt, str) => {
    const sf = fmt.slice(1, -1).replace(/yyyy/g, "%Y").replace(/yy/g, "%y").replace(/MMMM/g, "%B").replace(/MMM/g, "%b").replace(/MM/g, "%m").replace(/dd/g, "%d").replace(/HH/g, "%H").replace(/hh/g, "%I").replace(/mm/g, "%M").replace(/ss/g, "%S");
    if (warnings)
      warnings.push("\u26A0 DATEPARSE format translated to strftime tokens \u2014 verify the pattern resolves on your warehouse.");
    return `DateParse(${str.trim()}, "${sf}")`;
  });
  f = f.replace(/\bUSERNAME\s*\(\s*\)/gi, "CurrentUserEmail()");
  f = f.replace(/\bISMEMBEROF\s*\(\s*['"]([^'"]+)['"]\s*\)/gi, 'CurrentUserInTeam("$1")');
  f = f.replace(/\bUSERATTRIBUTE\s*\(\s*['"]([^'"]+)['"]\s*\)/gi, 'CurrentUserAttributeText("$1")');
  f = f.replace(/\bISUSERNAME\s*\(\s*['"]([^'"]+)['"]\s*\)/gi, '(CurrentUserEmail() = "$1")');
  for (const [tab, sig] of Object.entries(TABLEAU_FUNC_MAP)) {
    f = f.replace(new RegExp("\\b" + tab + "\\s*\\(", "gi"), sig + "(");
  }
  f = f.replace(/'([^']*)'/g, '"$1"');
  f = f.replace(/\bNOT\b/g, "Not").replace(/\bAND\b/g, "and").replace(/\bOR\b/g, "or");
  f = f.replace(/\bTRUE\b/gi, "True").replace(/\bFALSE\b/gi, "False").replace(/\bNULL\b/gi, "null");
  f = f.replace(/\[([A-Z][A-Z0-9_]{2,})\]/g, (match, colName) => {
    if (colName === colName.toLowerCase() || colName.includes(" "))
      return match;
    return "[" + sigmaDisplayName(colName) + "]";
  });
  f = tableauTextConcatToSigma(f);
  if (warnings && TABLEAU_TABLE_CALC_TOKEN_RE.test(f)) {
    warnings.push(`\u26A0 Table-calc function embedded in a larger expression \u2014 NOT translated in place. Untranslated fragment: ${f.slice(0, 120)}`);
  }
  return f.trim();
}
function tableauIsAggregate(formula) {
  return /\b(SUM|AVG|COUNT|COUNTD|MAX|MIN|MEDIAN|STDEV|STDEVP|VAR|VARP|PERCENTILE|CORR|ATTR)\s*\(/i.test(formula);
}
function tableauFormulaIsRls(formula) {
  return /\b(USERNAME|FULLNAME|USERDOMAIN|ISMEMBEROF|ISUSERNAME|USERATTRIBUTE)\s*\(/i.test(formula || "");
}

// ../../../../../../../../../../../Users/tjwells/sigma-data-model-mcp/build/tableau.js
function paramControlId(rawName) {
  return "ctl-" + rawName.replace(/[^a-zA-Z0-9]+/g, "-").replace(/^-|-$/g, "").toLowerCase();
}
var xmlParser = new import_fast_xml_parser.XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  isArray: (name) => [
    "datasource",
    "relation",
    "column",
    "member",
    "clause",
    "expression",
    "metadata-record",
    "relationship",
    "object",
    "worksheet",
    "filter",
    "rows",
    "cols"
  ].includes(name),
  trimValues: true,
  // fast-xml-parser caps total entity expansions at 1000 by default (a
  // billion-laughs DoS guard). Real Tableau .twb files are large, trusted,
  // first-party input dense with predefined entities (&quot; &amp; &gt; in
  // formulas/captions) — a 5MB workbook hit 1018 and failed to parse at all,
  // blocking the entire data-model build. These workbooks are not adversarial;
  // raise the limits well past any real file so big (and bigger) ones parse.
  processEntities: {
    enabled: true,
    maxTotalExpansions: 5e7,
    maxEntityCount: 5e6,
    maxExpandedLength: 5e8
  }
});
function asArray(val) {
  if (!val)
    return [];
  return Array.isArray(val) ? val : [val];
}
function attr(node, key) {
  return node && node[`@_${key}`] || "";
}
function connRelations(conn) {
  if (!conn)
    return [];
  if (conn.relation)
    return asArray(conn.relation);
  const nsKeys = Object.keys(conn).filter((k) => k.endsWith("...relation"));
  if (nsKeys.length === 0)
    return [];
  const pick = nsKeys.find((k) => k.includes(".true...")) || nsKeys[0];
  return asArray(conn[pick]);
}
function nsChild(obj, suffix) {
  if (!obj)
    return void 0;
  if (obj[suffix] != null)
    return obj[suffix];
  const keys = Object.keys(obj).filter((k) => k.endsWith(`...${suffix}`));
  if (keys.length === 0)
    return void 0;
  return obj[keys.find((k) => k.includes(".true...")) || keys[0]];
}
function nsAttr(node, key) {
  if (!node)
    return "";
  const bare = node[`@_${key}`];
  if (bare != null && bare !== "")
    return bare;
  const keys = Object.keys(node).filter((k) => k.startsWith("@_") && k.endsWith(`...${key}`));
  if (keys.length === 0)
    return "";
  return node[keys.find((k) => k.includes(".true...")) || keys[0]] || "";
}
function _tableauInnerToSql(expr) {
  let s = expr;
  s = s.replace(/\bZN\s*\(([^()]+)\)/gi, "$1");
  s = s.replace(/\[([^\]]+)\]/g, (_m, name) => name.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase());
  s = s.replace(/\/\s*([A-Z][A-Z0-9_]*)\b/g, "/NULLIF($1,0)");
  return s;
}
function tableauParseLOD(formula) {
  const m = formula.match(/^\{\s*(FIXED|INCLUDE|EXCLUDE)\s*(.*?)\s*:\s*(.*?)\s*\}$/is);
  if (!m)
    return null;
  const lodType = m[1].toUpperCase();
  const rawDims = m[2].trim();
  const rawAgg = m[3].trim();
  const dims = [];
  if (rawDims) {
    const dimRefs = rawDims.match(/\[([^\]]+)\]/g) || [];
    for (const ref of dimRefs)
      dims.push(ref.replace(/^\[|\]$/g, ""));
  }
  const aggMatch = rawAgg.match(/^(SUM|AVG|MIN|MAX|COUNTD|COUNT)\s*\(([\s\S]+)\)\s*$/i);
  let aggFunc = "SUM";
  let innerExpr = rawAgg;
  if (aggMatch) {
    aggFunc = aggMatch[1].toUpperCase();
    innerExpr = aggMatch[2].trim();
  }
  const aggExpr = _tableauInnerToSql(innerExpr);
  let sigmaAgg = rawAgg;
  sigmaAgg = sigmaAgg.replace(/\bSUM\s*\(/gi, "Sum(");
  sigmaAgg = sigmaAgg.replace(/\bAVG\s*\(/gi, "Avg(");
  sigmaAgg = sigmaAgg.replace(/\bMIN\s*\(/gi, "Min(");
  sigmaAgg = sigmaAgg.replace(/\bMAX\s*\(/gi, "Max(");
  sigmaAgg = sigmaAgg.replace(/\bCOUNTD\s*\(/gi, "CountDistinct(");
  sigmaAgg = sigmaAgg.replace(/\bCOUNT\s*\(([^)]+)\)/gi, "CountIf(IsNotNull($1))");
  sigmaAgg = sigmaAgg.replace(/\[([A-Z][A-Z0-9_]{2,})\]/g, (_m, colName) => {
    if (colName.includes(" "))
      return `[${colName}]`;
    return "[" + sigmaDisplayName(colName) + "]";
  });
  return { _isLOD: true, lodType, dims, rawAgg, aggFunc, aggExpr, sigmaAgg };
}
function _windowInnerToSql(expr) {
  let s = expr;
  s = s.replace(/\bZN\s*\(([^()]+)\)/gi, "$1");
  s = s.replace(/\[([^\]]+)\]/g, (_m, name) => name.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase());
  return s;
}
function tableauParseWindow(formula) {
  const f = formula.trim();
  if (!/^(WINDOW_|RUNNING_|LOOKUP\(|RANK\b|RANK_DENSE\b|RANK_UNIQUE\b|INDEX\(|FIRST\(|LAST\()/i.test(f)) {
    return null;
  }
  if (/^PREVIOUS_VALUE\s*\(/i.test(f))
    return null;
  let m = f.match(/^(RUNNING_(?:SUM|AVG|MIN|MAX))\s*\(\s*(SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(\[[^\]]+\]|[A-Z0-9_]+)\s*\)\s*\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: m[1].toUpperCase(),
      innerAggFunc: m[2].toUpperCase(),
      innerColRaw: m[3],
      innerExprSql: _windowInnerToSql(m[3])
    };
  m = f.match(/^(RUNNING_(?:SUM|AVG|MIN|MAX))\s*\(\s*(\[[^\]]+\]|[A-Z0-9_]+)\s*\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: m[1].toUpperCase(),
      innerAggFunc: "SUM",
      innerColRaw: m[2],
      innerExprSql: _windowInnerToSql(m[2])
    };
  m = f.match(/^(WINDOW_(?:SUM|AVG|MIN|MAX|COUNT))\s*\(\s*(SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(\[[^\]]+\]|[A-Z0-9_]+)\s*\)\s*\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: m[1].toUpperCase(),
      innerAggFunc: m[2].toUpperCase(),
      innerColRaw: m[3],
      innerExprSql: _windowInnerToSql(m[3])
    };
  m = f.match(/^LOOKUP\s*\(\s*(SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(\[[^\]]+\]|[A-Z0-9_]+)\s*\)\s*,\s*(-?\d+)\s*\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: "LOOKUP",
      innerAggFunc: m[1].toUpperCase(),
      innerColRaw: m[2],
      innerExprSql: _windowInnerToSql(m[2]),
      lookupOffset: parseInt(m[3], 10)
    };
  m = f.match(/^(FIRST|LAST)\s*\(\s*\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: m[1].toUpperCase(),
      innerAggFunc: "",
      innerColRaw: "",
      innerExprSql: ""
    };
  m = f.match(/^(RANK|RANK_DENSE|RANK_UNIQUE)\s*\(\s*\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: m[1].toUpperCase(),
      innerAggFunc: "",
      innerColRaw: "",
      innerExprSql: "",
      rankDirection: "desc"
    };
  m = f.match(/^(RANK|RANK_DENSE|RANK_UNIQUE)\s*\(\s*(SUM|AVG|MIN|MAX|COUNT)\s*\(\s*(\[[^\]]+\]|[A-Z0-9_]+)\s*\)\s*(?:,\s*['"]?(asc|desc)['"]?\s*)?\)\s*$/i);
  if (m)
    return {
      _isWindow: true,
      windowType: m[1].toUpperCase(),
      innerAggFunc: m[2].toUpperCase(),
      innerColRaw: m[3],
      innerExprSql: _windowInnerToSql(m[3]),
      rankDirection: (m[4] || "desc").toLowerCase()
    };
  if (/^INDEX\s*\(\s*\)\s*$/i.test(f))
    return {
      _isWindow: true,
      windowType: "INDEX",
      innerAggFunc: "",
      innerColRaw: "",
      innerExprSql: ""
    };
  return null;
}
function _parseWindowAddressing(calcEl) {
  if (!calcEl)
    return null;
  const tc = calcEl["table-calculation"];
  if (!tc)
    return null;
  const tcNode = Array.isArray(tc) ? tc[0] : tc;
  if (!tcNode)
    return null;
  const direction = (attr(tcNode, "direction") || "").toLowerCase();
  const scope = (attr(tcNode, "scope") || "").toLowerCase();
  const addresses = asArray(tcNode["address"] || tcNode.address || []);
  const orderFields = [];
  for (const a of addresses) {
    const refName = attr(a, "ref-name") || "";
    const cleaned = refName.replace(/^\[|\]$/g, "");
    const colonStripped = cleaned.match(/^(?:yr|mn|qr|dy|wk|md):([^:]+)(?::[a-z]{2})?$/i);
    const bare = colonStripped ? colonStripped[1] : cleaned;
    if (bare)
      orderFields.push(bare.toUpperCase());
  }
  if (orderFields.length > 0) {
    return { mode: "specific", orderFields, rawDirection: direction || void 0 };
  }
  if (scope === "pane" || scope === "cell") {
    return { mode: "unknown", orderFields: [], rawDirection: `${scope}/${direction}` };
  }
  if (direction === "right" || direction === "left") {
    return { mode: "table-across", orderFields: [], rawDirection: direction };
  }
  if (direction === "down" || direction === "up") {
    return { mode: "table-down", orderFields: [], rawDirection: direction };
  }
  return null;
}
function _windowAlias(caption, used) {
  let base = (caption || "WIN_VAL").toUpperCase().replace(/[^A-Z0-9_]+/g, "_").replace(/^_+|_+$/g, "").replace(/_+/g, "_");
  if (!base)
    base = "WIN_VAL";
  let alias = base;
  let n = 2;
  while (used.has(alias)) {
    alias = `${base}_${n++}`;
  }
  used.add(alias);
  return alias;
}
function _stripBrackets(s) {
  return (s || "").replace(/^\[|\]$/g, "").trim();
}
function tableauParseTopNSet(calcEl, caption, setName) {
  if (!calcEl)
    return null;
  if (attr(calcEl, "class") !== "categorical-set")
    return null;
  const groupFilters = asArray(calcEl.groupfilter || []);
  let endFilter = null;
  for (const gf of groupFilters) {
    if (attr(gf, "function") === "end") {
      endFilter = gf;
      break;
    }
  }
  if (!endFilter)
    return null;
  const rawDim = attr(endFilter, "field");
  const rawCount = attr(endFilter, "count");
  const rawCountCtl = attr(endFilter, "count-control");
  const direction = (attr(endFilter, "direction") || "top").toLowerCase();
  const dimField = _stripBrackets(rawDim).toUpperCase();
  if (!dimField)
    return null;
  let count = null;
  let countControl = null;
  if (rawCount)
    count = parseInt(rawCount, 10);
  else if (rawCountCtl)
    countControl = _stripBrackets(rawCountCtl);
  if (count === null && countControl === null)
    return null;
  let byField = "";
  let byAggFunc = "SUM";
  const partitionBy = [];
  function walk(node) {
    if (!node || typeof node !== "object")
      return;
    const fn = attr(node, "function");
    if (fn === "aggregation") {
      const opField = attr(node, "user:op-field") || attr(node, "op-field");
      const op = (attr(node, "user:op") || attr(node, "op") || "SUM").toUpperCase();
      if (opField)
        byField = _stripBrackets(opField).toUpperCase();
      byAggFunc = op === "COUNTD" ? "COUNTD" : op;
    }
    if (fn === "filter") {
      const partRaw = attr(node, "user:partition-by") || attr(node, "partition-by");
      if (partRaw) {
        const matches = partRaw.match(/\[[^\]]+\]/g) || [];
        for (const m of matches)
          partitionBy.push(_stripBrackets(m).toUpperCase());
      }
    }
    for (const k of Object.keys(node)) {
      if (k.startsWith("@_"))
        continue;
      const v = node[k];
      if (Array.isArray(v))
        for (const x of v)
          walk(x);
      else if (v && typeof v === "object")
        walk(v);
    }
  }
  walk(endFilter);
  if (!byField)
    return null;
  return {
    _isTopN: true,
    setName,
    caption,
    dimField,
    byField,
    byAggFunc,
    count,
    countControl,
    direction,
    partitionBy
  };
}
function _topNAlias(caption, used) {
  let base = (caption || "TOPN").toUpperCase().replace(/[^A-Z0-9_]+/g, "_").replace(/^_+|_+$/g, "").replace(/_+/g, "_");
  if (!base)
    base = "TOPN";
  let alias = base;
  let n = 2;
  while (used.has(alias)) {
    alias = `${base}_${n++}`;
  }
  used.add(alias);
  return alias;
}
function _tableauPrefixToDateTrunc(prefix) {
  if (!prefix)
    return null;
  switch (prefix.toLowerCase()) {
    case "yr":
      return "year";
    case "qr":
      return "quarter";
    case "mn":
      return "month";
    case "wk":
      return "week";
    case "dy":
      return "day";
    case "md":
      return "day";
    default:
      return null;
  }
}
function _buildWindowWorksheetIndex(parsed) {
  const byField = /* @__PURE__ */ new Map();
  const worksheets = asArray(parsed?.workbook?.worksheets?.worksheet || []);
  for (const ws of worksheets) {
    const tbl = ws.table || ws;
    const rowRefs = [];
    const colRefs = [];
    let dateDim;
    let dateGrain = null;
    for (const r of asArray(tbl?.rows || [])) {
      const text = typeof r === "string" ? r : r["#text"] || "";
      for (const ref of _extractFieldRefsFromShelf(text))
        rowRefs.push(ref.toUpperCase());
    }
    for (const c of asArray(tbl?.cols || [])) {
      const text = typeof c === "string" ? c : c["#text"] || "";
      const re = /\[[^\]]+\]\.\[([^\]]+)\]/g;
      let mm;
      while ((mm = re.exec(text)) !== null) {
        const inner = mm[1];
        const colon = inner.match(/^(yr|mn|qr|dy|wk|md):([^:]+):[a-z]{2}$/i);
        if (colon) {
          dateDim = colon[2].toUpperCase();
          dateGrain = _tableauPrefixToDateTrunc(colon[1]);
          colRefs.push(dateDim);
        } else {
          const colon2 = inner.match(/^[a-z]{2,5}:([^:]+):[a-z]{2}$/i);
          colRefs.push((colon2 ? colon2[1] : inner).toUpperCase());
        }
      }
    }
    const view = tbl?.view || {};
    const deps = asArray(view["datasource-dependencies"] || []);
    const dimFields = /* @__PURE__ */ new Set();
    const usedFields = /* @__PURE__ */ new Set([...rowRefs, ...colRefs]);
    for (const d of deps) {
      for (const col of asArray(d.column || [])) {
        const role = attr(col, "role");
        const name = attr(col, "name").replace(/^\[|\]$/g, "");
        if (role === "dimension")
          dimFields.add(name.toUpperCase());
      }
    }
    const rowsDims = rowRefs.filter((r) => dimFields.has(r));
    const colsDims = colRefs.filter((c) => dimFields.has(c));
    const allDims = Array.from(/* @__PURE__ */ new Set([...rowsDims, ...colsDims]));
    for (const used of usedFields) {
      const list = byField.get(used) || [];
      list.push({ rowsDims: rowsDims.slice(), colsDims: colsDims.slice(), allDims: allDims.slice(), dateDim, dateGrain });
      byField.set(used, list);
    }
  }
  return { byField };
}
function _lodAlias(caption, used) {
  let base = (caption || "LOD_VAL").toUpperCase().replace(/[^A-Z0-9_]+/g, "_").replace(/^_+|_+$/g, "").replace(/_+/g, "_");
  if (!base)
    base = "LOD_VAL";
  let alias = base;
  let n = 2;
  while (used.has(alias)) {
    alias = `${base}_${n++}`;
  }
  used.add(alias);
  return alias;
}
function _extractFieldRefsFromShelf(text) {
  const refs = [];
  const re = /\[[^\]]+\]\.\[([^\]]+)\]/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    let inner = m[1];
    const colon = inner.match(/^[a-z]{2,5}:([^:]+):[a-z]{2}$/i);
    if (colon)
      inner = colon[1];
    refs.push(inner);
  }
  return refs;
}
function _buildWorksheetIndex(parsed) {
  const byField = /* @__PURE__ */ new Map();
  const worksheets = asArray(parsed?.workbook?.worksheets?.worksheet || []);
  for (const ws of worksheets) {
    const tbl = ws.table || ws;
    const viewDims = [];
    const usedFields = /* @__PURE__ */ new Set();
    const shelves = [];
    for (const r of asArray(tbl?.rows || []))
      shelves.push(typeof r === "string" ? r : r["#text"] || "");
    for (const c of asArray(tbl?.cols || []))
      shelves.push(typeof c === "string" ? c : c["#text"] || "");
    for (const s of shelves) {
      for (const ref of _extractFieldRefsFromShelf(s)) {
        usedFields.add(ref.toUpperCase());
      }
    }
    const view = tbl?.view || {};
    const deps = asArray(view["datasource-dependencies"] || []);
    const dimFieldNames = /* @__PURE__ */ new Set();
    for (const d of deps) {
      for (const col of asArray(d.column || [])) {
        const role = attr(col, "role");
        const name = attr(col, "name").replace(/^\[|\]$/g, "");
        if (role === "dimension")
          dimFieldNames.add(name.toUpperCase());
      }
    }
    for (const used of usedFields) {
      if (dimFieldNames.has(used))
        viewDims.push(used);
    }
    for (const used of usedFields) {
      const list = byField.get(used) || [];
      list.push({ dims: viewDims.slice() });
      byField.set(used, list);
    }
  }
  return { byField };
}
function normalizeColumnName(name) {
  return name.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_|_$/g, "").toUpperCase();
}
var _qid = (name) => `"${String(name).replace(/"/g, '""')}"`;
var _isNumericType = (t) => t === "integer" || t === "real";
function qualifyTwoPartFqns(sql, db) {
  if (!sql || !db)
    return sql;
  const qdb = /[^A-Za-z0-9_$]/.test(db) ? `"${db}"` : db;
  const part = `(?:"[^"]+"|[A-Za-z_$][\\w$]*)`;
  const re = new RegExp(`(\\b(?:FROM|JOIN)\\s+)(${part}(?:\\.${part})*)`, "gi");
  return sql.replace(re, (m, kw, ref) => {
    const parts = ref.match(new RegExp(part, "g")) || [];
    return parts.length === 2 ? `${kw}${qdb}.${ref}` : m;
  });
}
function collapseCustomSqlBlend(elements, connId, colSqlNameById, colTypeById, warnings) {
  const elById = new Map(elements.map((e) => [e.id, e]));
  const fact = elements.find((e) => e.source?.kind === "sql" && Array.isArray(e.relationships) && e.relationships.some((r) => elById.get(r.targetElementId)?.source?.kind === "sql"));
  if (!fact)
    return null;
  const sqlName = (colId) => colSqlNameById[colId] || colId.split("/").slice(1).join("/") || colId;
  const cleanAlias = (col) => {
    const m = typeof col.formula === "string" && col.formula.match(/\/([^\]]+)\]$/);
    return (m ? m[1] : col.name || sqlName(col.id)).trim();
  };
  const seen = /* @__PURE__ */ new Set();
  const rels = fact.relationships.filter((r) => elById.get(r.targetElementId)?.source?.kind === "sql").filter((r) => {
    const sig = r.targetElementId + "|" + (r.keys || []).map((k) => `${k.sourceColumnId}=${k.targetColumnId}`).sort().join(",");
    if (seen.has(sig))
      return false;
    seen.add(sig);
    return true;
  });
  if (rels.length < 2)
    return null;
  const ctes = [`__f AS (
${fact.source.statement}
)`];
  const joins = [];
  const outSelect = [];
  const mergedColumns = [];
  const order = [];
  const usedOut = /* @__PURE__ */ new Set();
  const uniq = (base) => {
    let a = base, i = 2;
    while (usedOut.has(a.toUpperCase()))
      a = `${base}_${i++}`;
    usedOut.add(a.toUpperCase());
    return a;
  };
  const emit = (sqlRef, col) => {
    const out = uniq(cleanAlias(col));
    outSelect.push(`  ${sqlRef} AS ${_qid(out)}`);
    mergedColumns.push({ id: col.id, name: out, formula: `[Custom SQL/${out}]` });
    order.push(col.id);
  };
  for (const col of fact.columns || [])
    emit(`__f.${_qid(sqlName(col.id))}`, col);
  rels.forEach((r, i) => {
    const sec = elById.get(r.targetElementId);
    if (!sec)
      return;
    const cte = `__s${i}`;
    const keyPairs = (r.keys || []).map((k) => ({
      factSql: sqlName(k.sourceColumnId),
      secSql: sqlName(k.targetColumnId)
    }));
    const keySecNames = new Set(keyPairs.map((p) => p.secSql));
    const nonKeyCols = (sec.columns || []).filter((c) => !keySecNames.has(sqlName(c.id)));
    const subSel = [];
    for (const p of keyPairs)
      subSel.push(`    ${_qid(p.secSql)} AS ${_qid(p.secSql)}`);
    for (const c of nonKeyCols) {
      const sn = sqlName(c.id);
      const agg = _isNumericType(colTypeById[c.id]) ? "SUM" : "MAX";
      subSel.push(`    ${agg}(${_qid(sn)}) AS ${_qid(sn)}`);
    }
    const grpBy = keyPairs.map((p) => _qid(p.secSql)).join(", ");
    ctes.push(`${cte} AS (
  SELECT
${subSel.join(",\n")}
  FROM (
${sec.source.statement}
) ${_qid(`__src_${i}`)}
  GROUP BY ${grpBy}
)`);
    joins.push(`LEFT JOIN ${cte} ON ` + keyPairs.map((p) => `__f.${_qid(p.factSql)} = ${cte}.${_qid(p.secSql)}`).join(" AND "));
    const partitionExpr = keyPairs.length ? `PARTITION BY ${keyPairs.map((p) => `__f.${_qid(p.factSql)}`).join(", ")}` : "";
    let deFanned = 0;
    for (const c of sec.columns || []) {
      const sn = sqlName(c.id);
      const isKey = keySecNames.has(sn);
      const isMeasure = !isKey && _isNumericType(colTypeById[c.id]);
      const ref = isMeasure && partitionExpr ? `${cte}.${_qid(sn)} / NULLIF(COUNT(*) OVER (${partitionExpr}), 0)` : `${cte}.${_qid(sn)}`;
      if (isMeasure && partitionExpr)
        deFanned++;
      emit(ref, c);
    }
    if (deFanned > 0) {
      warnings.push(`\u2139 Blend secondary "${sec.name || cte}": ${deFanned} measure(s) de-fanned (value \xF7 link-group row count) so Sum aggregates once per link key \u2014 coarse-grain goal/target measures now read correctly against fact-grain measures.`);
    }
  });
  const statement = `WITH ${ctes.join(",\n")}
SELECT
${outSelect.join(",\n")}
FROM __f
${joins.join("\n")}`;
  const factFrom = String(fact.source?.statement || "").match(/\bFROM\s+(?:"[^"]+"|[\w$]+)(?:\.(?:"[^"]+"|([\w$]+)))*/i);
  const mergedName = fact.name || (factFrom && factFrom[1] ? factFrom[1].replace(/"/g, "") : "BLEND") || "BLEND";
  warnings.push(`\u2139 Multi-source blend collapsed into one wide JOIN element: fact + ${rels.length} pre-aggregated secondary island(s) (link-grain SUM/MAX) \u2192 ${mergedColumns.length} columns. Charts can now resolve every column locally.`);
  return {
    mergedElement: { id: fact.id, name: mergedName, kind: "table", source: { connectionId: connId, kind: "sql", statement }, columns: mergedColumns, order },
    consumedIds: [fact.id, ...rels.map((r) => r.targetElementId)]
  };
}
function extractPath(rel, dbOverride, schOverride) {
  const rawTable = attr(rel, "table") || attr(rel, "name") || "";
  const cleaned = rawTable.replace(/[\[\]]/g, "").replace(/\s*\([^)]*\)/g, "");
  const parts = cleaned.split(".").filter(Boolean).map((s) => s.toUpperCase().trim()).filter((p) => !/^[0-9A-F]{8}-[0-9A-F]{4}-/i.test(p));
  const stripHash = (s) => s.replace(/_[0-9A-Fa-f]{16,}$/, "");
  let path;
  if (parts.length >= 2) {
    path = [...parts.slice(0, -1), stripHash(parts[parts.length - 1])];
  } else if (parts.length === 1) {
    path = [schOverride || "SCHEMA", stripHash(parts[0])];
  } else {
    path = [attr(rel, "name").toUpperCase() || "UNKNOWN"];
  }
  if (dbOverride) {
    if (path.length >= 3)
      path[0] = dbOverride;
    else
      path = [dbOverride, ...path];
  }
  if (schOverride) {
    if (path.length >= 3)
      path[1] = schOverride;
    else if (path.length === 2)
      path[0] = schOverride;
  }
  return path;
}
function collectTables(rel, tables) {
  const type = attr(rel, "type") || "table";
  if (type === "table") {
    tables.push({ rel, leftKey: "", rightKey: "", joinType: "" });
    return;
  }
  if (type === "join") {
    const joinType = attr(rel, "join") || "left";
    let leftKey = "", rightKey = "";
    const clauses = asArray(rel.clause);
    if (clauses.length > 0) {
      const exprs = asArray(clauses[0].expression);
      const eqExpr = exprs.find((e) => attr(e, "op") === "=");
      if (eqExpr) {
        const innerExprs = asArray(eqExpr.expression);
        if (innerExprs.length >= 2) {
          leftKey = attr(innerExprs[0], "op") || "";
          rightKey = attr(innerExprs[1], "op") || "";
        }
      }
    }
    const childRels = asArray(rel.relation);
    if (childRels.length === 2) {
      collectTables(childRels[0], tables);
      const beforeRight = tables.length;
      collectTables(childRels[1], tables);
      for (let i = beforeRight; i < tables.length; i++) {
        if (!tables[i].leftKey) {
          tables[i].joinType = joinType;
          tables[i].leftKey = leftKey;
          tables[i].rightKey = rightKey;
        }
      }
    } else {
      for (const child of childRels) {
        collectTables(child, tables);
      }
    }
  }
}
function blendColumns(dsEntry) {
  const conn = dsEntry?.ds?.connection;
  const out = [];
  const seen = /* @__PURE__ */ new Set();
  const push = (raw, isMeasure) => {
    const W = (raw || "").replace(/^\[|\]$/g, "").replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
    if (!W || seen.has(W))
      return;
    seen.add(W);
    out.push({ wh: W, display: sigmaDisplayName(W), isMeasure });
  };
  for (const mr of asArray(conn?.["metadata-records"]?.["metadata-record"] || [])) {
    const cls = mr["@_class"] || "";
    const remote = (mr["remote-name"] || "").trim();
    if (!remote)
      continue;
    const agg = (mr["aggregation"] || "").trim();
    const ltype = (mr["local-type"] || "").trim().toLowerCase();
    const isMeasure = cls === "measure" || ["integer", "real"].includes(ltype) && !!agg && agg !== "Count";
    push(remote, isMeasure);
  }
  if (out.length === 0) {
    const rel = connRelations(conn)[0];
    for (const col of asArray(rel?.columns?.column || [])) {
      const dt = (attr(col, "datatype") || "").toLowerCase();
      push(attr(col, "name"), ["integer", "real"].includes(dt));
    }
  }
  return out;
}
function blendFieldName(qualified) {
  const parts = (qualified || "").split("].[");
  let last = (parts[parts.length - 1] || qualified || "").replace(/^\[|\]$/g, "");
  const seg = last.split(":");
  if (seg.length >= 3)
    last = seg.slice(1, -1).join(":");
  return last.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
}
function tryBuildBlendModel(parsed, datasources, dbOverride, schOverride, connId) {
  const wb = parsed.workbook;
  const relsBlock = wb && wb["datasource-relationships"];
  if (!relsBlock)
    return null;
  const blendRels = asArray(relsBlock["datasource-relationship"]);
  if (blendRels.length === 0)
    return null;
  const warnings = [];
  const dsById = {};
  for (const d of datasources)
    dsById[attr(d.ds, "name")] = d;
  const primaryId = attr(blendRels[0], "source");
  const primary = dsById[primaryId];
  if (!primary)
    return null;
  const primaryRel = connRelations(primary.ds?.connection)[0];
  if (!primaryRel)
    return null;
  const links = [];
  for (const br of blendRels) {
    if (attr(br, "source") !== primaryId)
      continue;
    const secId = attr(br, "target");
    const sec = dsById[secId];
    if (!sec || !connRelations(sec.ds?.connection)[0]) {
      warnings.push(`\u26A0 Blend secondary '${secId}' has no warehouse table \u2014 skipped (publish/repoint it to a warehouse to include)`);
      continue;
    }
    const pairs = [];
    for (const m of asArray(br["column-mapping"]?.map || [])) {
      const p = blendFieldName(attr(m, "key")), s = blendFieldName(attr(m, "value"));
      if (p && s)
        pairs.push({ p, s });
    }
    if (pairs.length === 0) {
      warnings.push(`\u26A0 Blend to '${secId}' has no column mapping \u2014 skipped`);
      continue;
    }
    links.push({ sec, secId, pairs });
  }
  if (links.length === 0)
    return null;
  const elements = [];
  const pPath = extractPath(primaryRel, dbOverride, schOverride);
  const pTable = pPath[pPath.length - 1] || "PRIMARY";
  const pCols = blendColumns(primary);
  const pColId = {};
  const pBase = {
    id: sigmaShortId(),
    kind: "table",
    name: pTable,
    source: { connectionId: connId, kind: "warehouse-table", path: pPath },
    columns: [],
    order: [],
    relationships: []
  };
  for (const c of pCols) {
    const id = sigmaInodeId(c.wh);
    pBase.columns.push({ id, formula: `[${pTable}/${c.display}]`, name: c.display });
    pBase.order.push(id);
    pColId[c.wh] = { id, display: c.display };
  }
  elements.push(pBase);
  const pDims = pCols.filter((c) => !c.isMeasure);
  const pMeasures = pCols.filter((c) => c.isMeasure);
  const secMeasureDisplay = {};
  for (const link of links) {
    const sPath = extractPath(connRelations(link.sec.ds.connection)[0], dbOverride, schOverride);
    const sTable = sPath[sPath.length - 1] || "SECONDARY";
    const sCols = blendColumns(link.sec);
    const sLinkWh = new Set(link.pairs.map((p) => p.s));
    const sMeasures = sCols.filter((c) => c.isMeasure && !sLinkWh.has(c.wh));
    if (sMeasures.length === 0) {
      warnings.push(`\u26A0 Blend secondary ${sTable} has no measures to aggregate \u2014 skipped`);
      continue;
    }
    const sBase = {
      id: sigmaShortId(),
      kind: "table",
      name: sTable,
      source: { connectionId: connId, kind: "warehouse-table", path: sPath },
      columns: [],
      order: []
    };
    const sColId = {};
    for (const c of sCols) {
      const id = sigmaInodeId(c.wh);
      sBase.columns.push({ id, formula: `[${sTable}/${c.display}]`, name: c.display });
      sBase.order.push(id);
      sColId[c.wh] = id;
    }
    const sumIds = [];
    const sumMeta = [];
    for (const m of sMeasures) {
      const total = `Total ${m.display}`, id = sigmaShortId();
      sBase.columns.push({ id, formula: `Sum([${sTable}/${m.display}])`, name: total });
      sBase.order.push(id);
      sumIds.push(id);
      sumMeta.push({ display: m.display, total, srcWh: m.wh });
    }
    const sGroupId = sigmaShortId();
    sBase.groupings = [{ id: sGroupId, groupBy: link.pairs.map((p) => sColId[p.s]).filter(Boolean), calculations: sumIds }];
    elements.push(sBase);
    const sGrp = {
      id: sigmaShortId(),
      kind: "table",
      name: `${sTable}_BY_LINK`,
      source: { kind: "table", elementId: sBase.id, groupingId: sGroupId },
      columns: [],
      order: []
    };
    const sGrpLinkId = {};
    for (const p of link.pairs) {
      const disp = sCols.find((c) => c.wh === p.s)?.display || sigmaDisplayName(p.s);
      const id = sigmaShortId();
      sGrp.columns.push({ id, formula: `[${sTable}/${disp}]`, name: disp });
      sGrp.order.push(id);
      sGrpLinkId[p.s] = id;
    }
    for (const sm of sumMeta) {
      const id = sigmaShortId();
      sGrp.columns.push({ id, formula: `[${sTable}/${sm.total}]`, name: sm.total });
      sGrp.order.push(id);
    }
    elements.push(sGrp);
    const keys = link.pairs.map((p) => ({ sourceColumnId: pColId[p.p]?.id, targetColumnId: sGrpLinkId[p.s] })).filter((k) => k.sourceColumnId && k.targetColumnId);
    if (keys.length !== link.pairs.length) {
      warnings.push(`\u26A0 Blend ${pTable}\u2192${sTable}: some link columns not found on both sides \u2014 relationship may be incomplete`);
    }
    pBase.relationships.push({ id: sigmaShortId(), targetElementId: sGrp.id, keys, name: sTable });
    link;
    link._sumMeta = sumMeta;
    link._sTable = sTable;
  }
  const pLookup = {
    id: sigmaShortId(),
    kind: "table",
    name: `${pTable}_BLEND_DETAIL`,
    source: { kind: "table", elementId: pBase.id },
    columns: [],
    order: []
  };
  const calcIds = [];
  for (const d of pDims) {
    const id = sigmaShortId();
    pLookup.columns.push({ id, formula: `[${pTable}/${d.display}]`, name: d.display });
    pLookup.order.push(id);
  }
  const groupByIds = pLookup.order.slice();
  for (const m of pMeasures) {
    const id = sigmaShortId();
    pLookup.columns.push({ id, formula: `Sum([${pTable}/${m.display}])`, name: `Total ${m.display}` });
    pLookup.order.push(id);
    calcIds.push(id);
  }
  for (const link of links) {
    const sTable = link._sTable, sumMeta = link._sumMeta || [];
    for (const sm of sumMeta) {
      const lookId = sigmaShortId();
      const lookName = `${sm.display} (lookup)`;
      pLookup.columns.push({ id: lookId, formula: `[${pTable}/${sTable}/${sm.total}]`, name: lookName });
      pLookup.order.push(lookId);
      const maxId = sigmaShortId();
      pLookup.columns.push({ id: maxId, formula: `Max([${lookName}])`, name: sm.display });
      pLookup.order.push(maxId);
      calcIds.push(maxId);
      secMeasureDisplay[sm.srcWh] = sm.display;
    }
  }
  const secIds = new Set(links.map((l) => l.secId));
  for (const col of asArray(primary.ds?.column || [])) {
    const calc = col.calculation;
    if (!calc)
      continue;
    const formula = attr(calc, "formula");
    if (!formula)
      continue;
    const caption = (attr(col, "caption") || attr(col, "name") || "").replace(/^\[|\]$/g, "");
    const refsSec = secIds.size > 0 && [...secIds].some((id) => formula.includes(id)) || links.some((l) => formula.includes(`[${attr(l.sec.ds, "caption")}]`));
    if (!refsSec)
      continue;
    const m = formula.match(/^\s*SUM\(\s*\[([^\]]+)\]\s*\)\s*([-+*/])\s*SUM\(\s*\[([^\]]+)\]\.\[([^\]]+)\]\s*\)\s*$/i);
    let translated = null;
    if (m) {
      const localWh = m[1].replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
      const secWh = m[4].replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
      const localM = pMeasures.find((x) => x.wh === localWh);
      const secDisp = secMeasureDisplay[secWh];
      if (localM && secDisp)
        translated = `[Total ${localM.display}] ${m[2]} [${secDisp}]`;
    }
    if (translated) {
      const id = sigmaShortId();
      pLookup.columns.push({ id, formula: translated, name: caption });
      pLookup.order.push(id);
      calcIds.push(id);
      warnings.push(`\u2139 Cross-source calc "${caption}" \u2192 ${translated} (blended grain)`);
    } else {
      warnings.push(`\u26A0 Cross-source calc "${caption}" not auto-translated \u2014 recreate manually: ${formula.trim().slice(0, 140)}`);
    }
  }
  pLookup.groupings = [{ id: sigmaShortId(), groupBy: groupByIds, calculations: calcIds }];
  const pGroupId = pLookup.groupings[0].id;
  elements.push(pLookup);
  const pFinal = {
    id: sigmaShortId(),
    kind: "table",
    name: `${pTable}_BLENDED`,
    source: { kind: "table", elementId: pLookup.id, groupingId: pGroupId },
    columns: [],
    order: []
  };
  for (const d of pDims) {
    const id = sigmaShortId();
    pFinal.columns.push({ id, formula: `[${pLookup.name}/${d.display}]`, name: d.display });
    pFinal.order.push(id);
  }
  for (const cid of calcIds) {
    const src = pLookup.columns.find((c) => c.id === cid);
    if (!src)
      continue;
    const id = sigmaShortId();
    pFinal.columns.push({ id, formula: `[${pLookup.name}/${src.name}]`, name: src.name });
    pFinal.order.push(id);
  }
  elements.push(pFinal);
  warnings.unshift(`\u2139 Data blend detected: primary "${primary.name}" + ${links.length} secondary source(s) \u2192 merged data model (${elements.length} elements). Secondary measures pre-aggregated to link grain (Sigma relationships are many-to-one lookups); query the "${pTable}_BLENDED" element.`);
  if (!connId || connId === "<CONNECTION_ID>")
    warnings.push("\u26A0 Connection ID not set \u2014 update in JSON before saving to Sigma");
  const totalCols = elements.reduce((s, e) => s + (e.columns?.length || 0), 0);
  const totalRels = elements.reduce((s, e) => s + (e.relationships?.length || 0), 0);
  return {
    model: { name: primary.name, schemaVersion: 1, pages: [{ id: sigmaShortId(), name: "Page 1", elements }] },
    warnings,
    stats: {
      datasources: datasources.length,
      elements: elements.length,
      columns: totalCols,
      relationships: totalRels,
      metrics: 0,
      controls: 0,
      parameters: 0,
      lodChildElements: 0
    }
  };
}
function convertTableauToSigma(xmlContent, options = {}) {
  resetIds();
  const { connectionId = "", database = "", schema = "", datasourceIndex = 0 } = options;
  const dbOverride = (database || "").toUpperCase();
  const schOverride = (schema || "").toUpperCase();
  let parsed;
  try {
    parsed = xmlParser.parse(xmlContent);
  } catch (e) {
    throw new Error("XML parse error: " + e.message);
  }
  let allDs;
  if (parsed.workbook) {
    allDs = asArray(parsed.workbook?.datasources?.datasource || []);
  } else if (parsed.datasource) {
    allDs = asArray(parsed.datasource);
  } else {
    throw new Error("Unrecognized XML \u2014 expected <workbook> or <datasource> root element");
  }
  const parameters = [];
  const datasources = [];
  const topNParamControls = {};
  for (const ds2 of allDs) {
    if (attr(ds2, "hasconnection") === "false" || attr(ds2, "name") === "Parameters") {
      for (const col of asArray(ds2.column)) {
        const colName = attr(col, "caption") || attr(col, "name") || "";
        const rawName = attr(col, "name") || "";
        const colType = attr(col, "datatype") || "string";
        const domainType = attr(col, "param-domain-type") || "all";
        const unq = (v) => decodeXmlEntities(v).replace(/\\(.)/g, "$1").replace(/^"|"$/g, "");
        const members = asArray(col.members?.member).map((m) => unq(attr(m, "value"))).filter(Boolean);
        const calcEl = col.calculation;
        parameters.push({
          name: colName.replace(/^\[|\]$/g, ""),
          rawName: rawName.replace(/^\[|\]$/g, ""),
          type: colType,
          domainType,
          members,
          currentValue: unq(attr(col, "value")),
          defaultVal: calcEl ? attr(calcEl, "formula") : ""
        });
      }
      continue;
    }
    const name = attr(ds2, "caption") || attr(ds2, "name") || "Unnamed";
    const connection = ds2.connection;
    const connClass = connection ? attr(connection, "class") : "";
    const dbname = connection ? attr(connection, "dbname") || attr(connection, "database") : "";
    const schemaName = connection ? attr(connection, "schema") : "";
    datasources.push({ name, ds: ds2, connection, connClass, dbname, schema: schemaName });
  }
  if (datasources.length === 0) {
    throw new Error("No data sources found in the Tableau file");
  }
  const blendResult = tryBuildBlendModel(parsed, datasources, dbOverride, schOverride, connectionId || "<CONNECTION_ID>");
  if (blendResult) {
    try {
      const stripped = xmlContent.replace(/<datasource-relationships>[\s\S]*?<\/datasource-relationships>/g, "");
      if (stripped !== xmlContent) {
        const single = convertTableauToSigma(stripped, options);
        const harvest = (single.workbookPatterns || []).map(({ elementId, elementName, ...rest }) => rest);
        const base = blendResult.workbookPatterns || [];
        const merged = [...base, ...harvest.filter((p) => !base.some((b) => b.name === p.name && b.kind === p.kind))];
        if (merged.length)
          blendResult.workbookPatterns = merged;
        const n = merged.length - base.length;
        if (n > 0)
          blendResult.warnings.push(`\u2139 Native-blend workbook: recovered ${n} chart-context pattern(s) (param-switch/window/LOD/percent-of-total) from the primary datasource that the blend path would otherwise drop \u2014 reported in result.workbookPatterns (bead y9rd.7).`);
      }
    } catch {
    }
    return blendResult;
  }
  const dsIdx = Math.min(datasourceIndex, datasources.length - 1);
  const ds = datasources[dsIdx];
  const warnings = [];
  const security = [];
  const workbookPatterns = [];
  function _reportChartWindowPattern(caption, formula, why) {
    const chartWin = tableauWindowToSigmaChart(formula);
    if (chartWin) {
      workbookPatterns.push({
        kind: chartWin.kind,
        name: caption,
        source: formula.trim(),
        formula: chartWin.formula,
        requires: "GROUPED workbook element (group by the chart/viz dimensions) \u2014 NOT valid as a DM calc column or metric",
        ...chartWin.verify ? { verify: true } : {},
        note: `${why}. Place the ready formula in a grouped workbook element (chart context); window functions silently error in DM element calc columns and workbook master calc columns.${chartWin.note ? " " + chartWin.note : ""}`
      });
      warnings.push(`\u2139 "${caption}": table calc \u2192 ready Sigma formula ${chartWin.formula} in result.workbookPatterns \u2014 CHART/grouped-element context only (${why}); not emitted as a DM column.`);
      return true;
    }
    const untrans = tableauWindowUntranslatable(formula);
    if (untrans) {
      workbookPatterns.push({
        kind: "unsupported",
        name: caption,
        source: formula.trim(),
        note: `${untrans}() has no Sigma equivalent \u2014 recreate manually. Untranslated fragment: ${formula.trim().slice(0, 160)}`
      });
      warnings.push(`\u26A0 "${caption}": ${untrans}() has no Sigma equivalent \u2014 NOT translated. Untranslated fragment: ${formula.trim().slice(0, 120)}`);
      return true;
    }
    return false;
  }
  const elements = [];
  const connId = connectionId || "<CONNECTION_ID>";
  const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const colTypeById = {};
  const guidCaption = {};
  const physicalGuidCaption = {};
  const guidOwnerRel = {};
  {
    for (const mp of asArray(ds.ds?.cols?.map || [])) {
      const key = (attr(mp, "key") || "").replace(/^\[|\]$/g, "");
      const val = attr(mp, "value") || "";
      const guid = (key.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
      const ownerRel = (val.match(/^\[([^\]]+)\]/) || [])[1];
      if (guid && ownerRel)
        guidOwnerRel[guid.toLowerCase()] = ownerRel;
    }
    for (const mr of asArray(ds.connection?.["metadata-records"]?.["metadata-record"] || [])) {
      if (attr(mr, "class") !== "column")
        continue;
      const guid = (mr["remote-name"] || "").trim();
      const cap = (mr["caption"] || "").trim();
      if (guid && GUID_RE.test(guid) && cap)
        guidCaption[guid.toLowerCase()] = cap;
    }
    for (const col of asArray(ds.ds?.column || [])) {
      const nm = (attr(col, "name") || "").replace(/^\[|\]$/g, "");
      const guid = (nm.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
      if (!guid)
        continue;
      const cap = (attr(col, "caption") || "").replace(/\s*\([^()]*\([^)]*\)\)\s*$/, "").trim();
      if (!cap)
        continue;
      const g = guid.toLowerCase();
      if (!guidCaption[g])
        guidCaption[g] = cap;
      if (!col.calculation && !physicalGuidCaption[g])
        physicalGuidCaption[g] = cap;
    }
  }
  const calcNameToCaption = {};
  for (const col of asArray(ds.ds?.column || [])) {
    if (!col.calculation)
      continue;
    const nm = (attr(col, "name") || "").replace(/^\[|\]$/g, "");
    if (!nm)
      continue;
    const emitted = (attr(col, "caption") || nm).trim();
    if (emitted)
      calcNameToCaption[nm] = emitted;
  }
  const CALC_REF_RE = /^(Calculation_\d+|.+_\d{6,})$/;
  let factRelName = null;
  const derivedRelColGuids = /* @__PURE__ */ new Set();
  for (const rel of connRelations(ds.connection)) {
    const scanRel = (r) => {
      for (const col of asArray(r?.columns?.column || [])) {
        const nm = (attr(col, "name") || "").replace(/^\[|\]$/g, "");
        const g = (nm.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
        if (g && (attr(col, "date-parse-format") || col.calculation))
          derivedRelColGuids.add(g.toLowerCase());
      }
      for (const child of asArray(r?.relation || []))
        scanRel(child);
    };
    scanRel(rel);
  }
  const rewriteGuidRefs = (formula) => decodeXmlEntities(formula).replace(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/gi, (m, g) => {
    const cap = guidCaption[g.toLowerCase()];
    return cap ? `[${cap}]` : m;
  }).replace(/\[([^\]]+)\]/g, (m, name) => {
    if (!CALC_REF_RE.test(name))
      return m;
    const cap = calcNameToCaption[name];
    return cap ? `[${cap}]` : m;
  });
  const rootRelation = ds.connection ? connRelations(ds.connection)[0] || null : null;
  if (rootRelation) {
    const relType = attr(rootRelation, "type") || "table";
    if (relType === "table") {
      const path = extractPath(rootRelation, dbOverride, schOverride);
      const tableName = path[path.length - 1] || "";
      const columns = [], order = [];
      for (const col of asArray(rootRelation?.columns?.column || [])) {
        const key = attr(col, "name").toUpperCase();
        if (!key)
          continue;
        const id = sigmaInodeId(key);
        columns.push({ id, formula: `[${tableName}/${sigmaDisplayName(key)}]` });
        order.push(id);
      }
      elements.push({
        id: sigmaShortId(),
        kind: "table",
        source: { connectionId: connId, kind: "warehouse-table", path },
        columns,
        order
      });
    } else if (relType === "join") {
      const tables = [];
      collectTables(rootRelation, tables);
      if (tables.length === 0) {
        warnings.push("\u26A0 Could not parse join structure");
      } else {
        const elementMap = {};
        for (const t of tables) {
          const path = extractPath(t.rel, dbOverride, schOverride);
          const tableName = path[path.length - 1] || attr(t.rel, "name") || "";
          if (elementMap[tableName])
            continue;
          const columns = [], order = [];
          for (const col of asArray(t.rel?.columns?.column || [])) {
            const key = attr(col, "name").toUpperCase();
            if (!key)
              continue;
            const id = sigmaInodeId(key);
            columns.push({ id, formula: `[${tableName}/${sigmaDisplayName(key)}]` });
            order.push(id);
          }
          const elemId = sigmaShortId();
          const el = {
            id: elemId,
            kind: "table",
            source: { connectionId: connId, kind: "warehouse-table", path },
            columns,
            order
          };
          const colIdMap = {};
          columns.forEach((c) => {
            const m = c.formula.match(/\/([^\]]+)\]$/);
            if (m) {
              colIdMap[m[1].toUpperCase()] = c.id;
              colIdMap[m[1].replace(/\s+/g, "_").toUpperCase()] = c.id;
            }
          });
          elementMap[tableName] = { element: el, colIdMap };
          elements.push(el);
        }
        const primaryTableName = extractPath(tables[0].rel, dbOverride, schOverride).pop() || "";
        const primaryEntry = elementMap[primaryTableName];
        for (let i = 1; i < tables.length; i++) {
          const t = tables[i];
          if (!t.leftKey || !t.rightKey)
            continue;
          const leftKey = t.leftKey.replace(/^\[|\]$/g, "").split(/[\.\]]\[?/).pop()?.replace(/\]$/, "").toUpperCase() || "";
          const rightKey = t.rightKey.replace(/^\[|\]$/g, "").split(/[\.\]]\[?/).pop()?.replace(/\]$/, "").toUpperCase() || "";
          const tgtName = extractPath(t.rel, dbOverride, schOverride).pop() || "";
          const tgtEntry = elementMap[tgtName];
          if (!primaryEntry || !tgtEntry)
            continue;
          let srcColId = primaryEntry.colIdMap[leftKey] || primaryEntry.colIdMap[sigmaDisplayName(leftKey).toUpperCase()];
          if (!srcColId) {
            srcColId = sigmaInodeId(leftKey);
            primaryEntry.element.columns.push({ id: srcColId, formula: `[${primaryTableName}/${sigmaDisplayName(leftKey)}]` });
            primaryEntry.element.order.push(srcColId);
            primaryEntry.colIdMap[leftKey] = srcColId;
          }
          let tgtColId = tgtEntry.colIdMap[rightKey] || tgtEntry.colIdMap[sigmaDisplayName(rightKey).toUpperCase()];
          if (!tgtColId) {
            tgtColId = sigmaInodeId(rightKey);
            tgtEntry.element.columns.push({ id: tgtColId, formula: `[${tgtName}/${sigmaDisplayName(rightKey)}]` });
            tgtEntry.element.order.push(tgtColId);
            tgtEntry.colIdMap[rightKey] = tgtColId;
          }
          if (!primaryEntry.element.relationships)
            primaryEntry.element.relationships = [];
          primaryEntry.element.relationships.push({
            id: sigmaShortId(),
            targetElementId: tgtEntry.element.id,
            keys: [{ sourceColumnId: srcColId, targetColumnId: tgtColId }],
            name: tgtName
          });
          warnings.push(`\u2139 Join ${primaryTableName} \u2192 ${tgtName} (${t.joinType || "left"}) on ${leftKey} = ${rightKey}`);
        }
        elements.sort((a, b) => {
          const aR = !!a.relationships?.length;
          const bR = !!b.relationships?.length;
          return aR === bR ? 0 : aR ? 1 : -1;
        });
      }
    } else if (relType === "collection") {
      const childRels = asArray(rootRelation.relation || []);
      if (childRels.length === 0) {
        warnings.push("\u26A0 Collection datasource has no child relations \u2014 skipped");
      } else {
        const metaByObjId = {};
        const metaByParent = {};
        const colSqlNameById = {};
        const metaRecords = asArray(ds.connection?.["metadata-records"]?.["metadata-record"] || []);
        const stripBrackets = (s) => s.replace(/^\[|\]$/g, "");
        for (const mr of metaRecords) {
          if (attr(mr, "class") !== "column")
            continue;
          const uuid = (mr["remote-name"] || "").trim();
          let cap = (mr["caption"] || mr["remote-alias"] || stripBrackets(mr["local-name"] || "") || uuid).trim();
          const objIdRaw = stripBrackets((mr["object-id"] || nsChild(mr, "object-id") || "").trim());
          const parentRaw = stripBrackets((mr["parent-name"] || "").trim());
          const localType = (mr["local-type"] || "").trim().toLowerCase();
          const remoteAlias = (mr["remote-alias"] || stripBrackets(mr["local-name"] || "") || "").trim();
          if (!uuid || !cap)
            continue;
          if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(cap)) {
            const known = physicalGuidCaption[uuid.toLowerCase()];
            warnings.push(known ? `\u26A0 Dropped column "${known}" (Tableau-renamed to internal GUID ${uuid}): its warehouse identity is the GUID, so a [TABLE/${known}] ref won't resolve in Sigma. Re-add manually if needed (needs warehouse-column\u2192display aliasing).` : `\u26A0 Dropped column "${uuid}" \u2014 referenced only by an internal Tableau GUID with no recoverable caption; emitting it would produce an unresolvable [TABLE/${uuid}] reference.`);
            continue;
          }
          const entry = { uuid, caption: cap, objId: objIdRaw || void 0, localType: localType || void 0, remoteAlias: remoteAlias || void 0 };
          if (objIdRaw)
            (metaByObjId[objIdRaw] ||= []).push(entry);
          if (parentRaw)
            (metaByParent[parentRaw] ||= []).push(entry);
        }
        const elementMap = {};
        const factChild = childRels.find((r) => asArray(r?.columns?.column || []).length > 0);
        factRelName = factChild ? attr(factChild, "name") || attr(factChild, "table") || null : null;
        for (const rel of childRels) {
          const fullName = attr(rel, "name") || attr(rel, "table") || "TABLE";
          const path = extractPath(rel, dbOverride, schOverride);
          const cleanName = path[path.length - 1] || fullName;
          const columns = [], order = [], colIdMap = {};
          let matchingObjId = Object.keys(metaByObjId).find((k) => k === fullName || k.startsWith(fullName + "_"));
          if (!matchingObjId) {
            const roleM = fullName.match(/^([\s\S]+?)(\d+)$/);
            if (roleM) {
              const base = roleM[1];
              const idx = parseInt(roleM[2], 10);
              const cands = Object.keys(metaByObjId).filter((k) => k === base || k.startsWith(base + "_")).sort();
              matchingObjId = cands[idx];
            }
          }
          let metaCols = matchingObjId ? metaByObjId[matchingObjId] : [];
          if (!metaCols.length)
            metaCols = metaByParent[fullName] || [];
          const relObjId = matchingObjId || metaCols.find((c) => c.objId)?.objId || null;
          const isCustomSqlRel = attr(rel, "type") === "text";
          const colPrefix = isCustomSqlRel ? "Custom SQL" : cleanName;
          for (const { uuid, caption, localType, remoteAlias } of metaCols) {
            const cleanCaption = caption.replace(/\s*\(.*\)$/, "").trim();
            const idKey = uuid.toUpperCase();
            const id = sigmaInodeId(idKey);
            if (localType)
              colTypeById[id] = localType;
            const rawSqlName = (remoteAlias || caption).replace(/\s*\([^)]*\)\s*$/, "").trim();
            colSqlNameById[id] = rawSqlName || cleanCaption;
            columns.push({ id, formula: `[${colPrefix}/${cleanCaption}]`, name: cleanCaption });
            order.push(id);
            colIdMap[idKey] = id;
            colIdMap[uuid.toUpperCase().replace(/-/g, "_")] = id;
            colIdMap[cleanCaption.toUpperCase()] = id;
            colIdMap[cleanCaption.toUpperCase().replace(/\s+/g, "_")] = id;
          }
          if (metaCols.length === 0) {
            for (const col of asArray(rel?.columns?.column || [])) {
              const rawCol = attr(col, "name") || "";
              const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(rawCol);
              const key = isUuid ? rawCol.toUpperCase() : normalizeColumnName(rawCol);
              if (!key)
                continue;
              const id = sigmaInodeId(key);
              const capAttr = attr(col, "caption");
              const displayName = isUuid ? capAttr || rawCol : sigmaDisplayName(key);
              columns.push({ id, formula: `[${colPrefix}/${displayName}]` });
              order.push(id);
              colIdMap[rawCol.toUpperCase()] = id;
              colIdMap[key] = id;
            }
          }
          const isCustomSql = isCustomSqlRel;
          const sqlText = isCustomSql ? qualifyTwoPartFqns(String(rel["#text"] ?? "").trim(), dbOverride) : "";
          const source = isCustomSql && sqlText ? { connectionId: connId, kind: "sql", statement: sqlText } : { connectionId: connId, kind: "warehouse-table", path };
          if (isCustomSql && !sqlText) {
            warnings.push(`\u26A0 Custom SQL relation "${fullName}" has no inline SQL text \u2014 emitted as a table path "${path.join(".")}"; verify or replace with the query.`);
          }
          const el = { id: sigmaShortId(), kind: "table", source, columns, order };
          elementMap[fullName] = { element: el, colIdMap, cleanName, objId: relObjId };
          elements.push(el);
        }
        const objGraph = nsChild(ds.ds, "object-graph");
        const relsList = asArray(objGraph?.relationships?.relationship || []);
        const getCleanSeg = (name) => name.replace(/[\[\]]/g, "").split(".").pop()?.replace(/_[0-9A-Fa-f]{16,}$/, "").toUpperCase() || "";
        const findEntry = (objId) => {
          const exactKey = Object.keys(elementMap).find((k) => elementMap[k].objId === objId);
          if (exactKey)
            return elementMap[exactKey];
          const cleanId = getCleanSeg(objId);
          const key = Object.keys(elementMap).find((k) => getCleanSeg(k) === cleanId);
          return key ? elementMap[key] : void 0;
        };
        const extractOpUuid = (opAttr) => {
          const fnWrap = opAttr.match(/^\w+\(\[?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]?\)$/i);
          return fnWrap ? fnWrap[1].toUpperCase() : "";
        };
        const parseOpRef = (opAttr) => {
          const uuidInFn = extractOpUuid(opAttr);
          if (uuidInFn)
            return uuidInFn;
          return opAttr.replace(/^\[|\]$/g, "").replace(/\s*\(.*\)$/, "").trim().toUpperCase();
        };
        for (const rel of relsList) {
          const firstEp = rel["first-end-point"];
          const secondEp = rel["second-end-point"];
          if (!firstEp || !secondEp)
            continue;
          const firstEntry = findEntry(attr(firstEp, "object-id"));
          const secondEntry = findEntry(attr(secondEp, "object-id"));
          if (!firstEntry || !secondEntry || firstEntry === secondEntry)
            continue;
          const ensureCol = (entry, key) => {
            let id = entry.colIdMap[key] || entry.colIdMap[key.replace(/-/g, "_")];
            if (!id) {
              id = sigmaInodeId(key.replace(/\s+/g, "_"));
              const isUuid = /^[0-9A-F]{8}-[0-9A-F]{4}-/i.test(key);
              const cap = isUuid ? guidCaption[key.toLowerCase()] : void 0;
              const dispName = cap || (isUuid ? key : sigmaDisplayName(key));
              const colObj = { id, formula: `[${entry.cleanName}/${dispName}]` };
              if (cap)
                colObj.name = cap;
              entry.element.columns.push(colObj);
              entry.element.order.push(id);
              entry.colIdMap[key] = id;
              if (cap) {
                entry.colIdMap[cap.toUpperCase()] = id;
                entry.colIdMap[cap.toUpperCase().replace(/\s+/g, "_")] = id;
              }
            }
            return id;
          };
          const collectEqs = (expr, acc) => {
            const op = nsAttr(expr, "op");
            const kids = asArray(expr.expression || []);
            if (op === "=" && kids.length >= 2) {
              acc.push(expr);
              return;
            }
            for (const k of kids)
              collectEqs(k, acc);
          };
          const eqExprs = [];
          for (const oe of asArray(rel.expression || []))
            collectEqs(oe, eqExprs);
          if (eqExprs.length === 0)
            continue;
          const isPhysical = (op) => /^\[[^\]]+\]$/.test(op.trim());
          const keys = [];
          let skippedComputed = 0;
          for (const eq of eqExprs) {
            const inner = asArray(eq.expression || []);
            if (inner.length < 2)
              continue;
            const srcOpRaw = nsAttr(inner[0], "op") || "";
            const tgtOpRaw = nsAttr(inner[1], "op") || "";
            if (!isPhysical(srcOpRaw) || !isPhysical(tgtOpRaw)) {
              skippedComputed++;
              continue;
            }
            const srcKey = parseOpRef(srcOpRaw), tgtKey = parseOpRef(tgtOpRaw);
            if (!srcKey || !tgtKey)
              continue;
            keys.push({
              sourceColumnId: ensureCol(firstEntry, srcKey),
              targetColumnId: ensureCol(secondEntry, tgtKey)
            });
          }
          if (keys.length === 0) {
            warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName} joins only on computed key(s) (e.g. IF/DATETRUNC expression); Sigma joins on physical columns only \u2014 NOT wired. Needs a computed join column or manual authoring.`);
            continue;
          }
          if (skippedComputed > 0) {
            warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName}: wired ${keys.length} physical key(s); ${skippedComputed} computed condition(s) dropped \u2014 verify join grain in Sigma.`);
          }
          if (!firstEntry.element.relationships)
            firstEntry.element.relationships = [];
          firstEntry.element.relationships.push({
            id: sigmaShortId(),
            targetElementId: secondEntry.element.id,
            keys,
            name: secondEntry.cleanName
          });
          warnings.push(`\u2139 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName} wired on ${keys.length} physical key(s).`);
        }
        elements.sort((a, b) => {
          const aR = !!a.relationships?.length;
          const bR = !!b.relationships?.length;
          return aR === bR ? 0 : aR ? 1 : -1;
        });
        const blend = collapseCustomSqlBlend(elements, connId, colSqlNameById, colTypeById, warnings);
        if (blend) {
          const consumed = new Set(blend.consumedIds);
          for (let i = elements.length - 1; i >= 0; i--) {
            if (consumed.has(elements[i].id))
              elements.splice(i, 1);
          }
          elements.push(blend.mergedElement);
        } else {
          const sqlEls = elements.filter((e) => e.source?.kind === "sql");
          if (sqlEls.length === 1) {
            const el = sqlEls[0];
            if (!el.name)
              el.name = "Custom SQL";
            for (const c of el.columns || []) {
              const raw = colSqlNameById[c.id];
              if (raw)
                c.formula = `[Custom SQL/${raw}]`;
            }
          }
        }
        if (!dbOverride || !schOverride) {
          warnings.push("\u26A0 Virtual connection: pass database and schema parameters to set the full warehouse path.");
        }
      }
    } else if (relType === "text") {
      const decodeNumericEntities = (s) => s.replace(/&#x([0-9a-fA-F]+);/g, (_m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (_m, d) => String.fromCodePoint(parseInt(d, 10)));
      const statement = decodeNumericEntities((rootRelation["#text"] || "").toString()).trim();
      if (!statement) {
        warnings.push("\u26A0 Custom SQL relation carried no SQL text \u2014 no element emitted.");
      } else {
        const capByName = {};
        for (const col of asArray(ds.ds?.column || [])) {
          const nm = (attr(col, "name") || "").replace(/^\[|\]$/g, "");
          const cap = attr(col, "caption");
          if (nm && cap)
            capByName[nm.toUpperCase()] = cap;
        }
        const rawCols = [];
        for (const col of asArray(rootRelation?.columns?.column || [])) {
          const nm = attr(col, "name");
          if (nm)
            rawCols.push({ name: nm });
        }
        if (rawCols.length === 0) {
          for (const mr of asArray(ds.connection?.["metadata-records"]?.["metadata-record"] || [])) {
            if (attr(mr, "class") !== "column")
              continue;
            const remote = (mr["remote-name"] || "").trim();
            if (remote)
              rawCols.push({ name: remote });
          }
        }
        const columns = [], order = [];
        const seen = /* @__PURE__ */ new Set();
        for (const rc of rawCols) {
          const clean = rc.name.replace(/^\[|\]$/g, "");
          const upper = clean.toUpperCase();
          if (!clean || seen.has(upper))
            continue;
          seen.add(upper);
          const colKey = clean.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
          const display = capByName[upper] || sigmaDisplayName(clean);
          const id = sigmaInodeId(colKey);
          columns.push({ id, formula: `[Custom SQL/${colKey}]`, name: display });
          order.push(id);
        }
        elements.push({
          id: sigmaShortId(),
          kind: "table",
          source: { connectionId: connId, kind: "sql", statement },
          columns,
          order
        });
        if (columns.length === 0) {
          warnings.push("\u26A0 Custom SQL element emitted with no columns (no <columns> projection or column metadata-records found) \u2014 add columns from the query output.");
        } else {
          warnings.push(`\u2139 Custom SQL datasource \u2192 Sigma SQL element (source.kind:'sql', ${columns.length} column(s)). The SQL statement is preserved verbatim; verify column display names resolve against the query output.`);
        }
      }
    }
  }
  const factEl = elements.find((e) => e.relationships?.length > 0) || (elements.length > 0 ? elements.reduce((best, e) => (e.columns?.length || 0) > (best.columns?.length || 0) ? e : best, elements[0]) : null);
  if (factEl) {
    let _baseFromExpr2 = function() {
      const fe = factEl;
      if (fe?.source?.kind === "sql" && fe.source.statement) {
        const stmt = fe.source.statement;
        const upperStmt = stmt.trimStart();
        if (/^WITH\s/i.test(upperStmt)) {
          let depth = 0;
          let lastTopSelectIdx = -1;
          for (let i = 0; i < stmt.length; i++) {
            const ch = stmt[i];
            if (ch === "(") {
              depth++;
              continue;
            }
            if (ch === ")") {
              depth--;
              continue;
            }
            if (depth === 0 && /^SELECT\b/i.test(stmt.slice(i))) {
              lastTopSelectIdx = i;
            }
          }
          if (lastTopSelectIdx > 0) {
            const ctePart = stmt.slice(0, lastTopSelectIdx).replace(/^\s*WITH\s+/i, "").replace(/,?\s*$/, "");
            const selectPart = stmt.slice(lastTopSelectIdx);
            return {
              ctePrefix: `${ctePart},
__lod_base AS (
${selectPart}
),
`,
              fromClause: "__lod_base"
            };
          }
        }
        return { fromClause: `(
${stmt}
) __base`, ctePrefix: "" };
      }
      const fqPath = fe?.source?.path && fe.source.path.length >= 2 ? fe.source.path.join(".") : factTableName;
      return { fromClause: fqPath, ctePrefix: "" };
    }, _resolveDimDisplayName2 = function(dimNameRaw) {
      const found = displayNameMap[dimNameRaw.toUpperCase()] || displayNameMap[sigmaDisplayName(dimNameRaw).toUpperCase()];
      if (!found)
        return null;
      const parentCol = found.el.columns?.find((c) => c.id === found.colId);
      const dn = parentCol?.name || parentCol?.formula.match(/\/([^\]]+)\]$/)?.[1] || dimNameRaw;
      const fm = parentCol?.formula.match(/\/([^\]]+)\]$/);
      const dispName = dn;
      const dimUpper = dispName.replace(/\s+/g, "_").toUpperCase();
      const physicalUpper = (fm ? fm[1] : dispName).replace(/\s+/g, "_").toUpperCase();
      return { dimUpper: physicalUpper, displayName: dispName, baseColId: found.colId, onFact: found.el === factEl };
    }, _ensureHelper2 = function(effectiveDims, dimResolved, relNameSuggestion) {
      if (effectiveDims.length === 0)
        return null;
      const signatureKey = effectiveDims.slice().sort().join(",");
      const existing = lodHelpers[signatureKey];
      if (existing)
        return { helper: existing.element, signatureKey };
      const helperId = sigmaShortId();
      const helperCols = [];
      const helperOrder = [];
      const groupDimColIds = [];
      for (const d of dimResolved) {
        const colId = sigmaShortId();
        helperCols.push({ id: colId, formula: `[Custom SQL/${d.dimUpper}]`, name: d.displayName });
        helperOrder.push(colId);
        groupDimColIds.push(colId);
      }
      const helperEl = {
        id: helperId,
        kind: "table",
        name: relNameSuggestion,
        source: {
          connectionId: connId,
          kind: "sql",
          statement: "__PLACEHOLDER__"
          // filled in below once aggs are known
        },
        columns: helperCols,
        order: helperOrder
      };
      lodHelpers[signatureKey] = {
        element: helperEl,
        groupDimNames: effectiveDims.slice(),
        groupDimDisplayNames: dimResolved.map((d) => d.displayName),
        groupDimColIds,
        aggsByExpr: {},
        relationshipName: relNameSuggestion
      };
      lodChildElements.push(helperEl);
      return { helper: helperEl, signatureKey };
    }, _ensureRelationship2 = function(sigKey, dimResolved, relName) {
      const rec = lodHelpers[sigKey];
      if (!rec)
        return;
      const existing = factEl.relationships || [];
      if (existing.find((r) => r.targetElementId === rec.element.id))
        return;
      const keys = [];
      for (let i = 0; i < dimResolved.length; i++) {
        const baseColId = dimResolved[i].baseColId;
        const helperColId = rec.groupDimColIds[i];
        if (!baseColId || !helperColId)
          return;
        keys.push({ sourceColumnId: baseColId, targetColumnId: helperColId });
      }
      if (!factEl.relationships)
        factEl.relationships = [];
      factEl.relationships.push({
        id: sigmaShortId(),
        targetElementId: rec.element.id,
        keys,
        name: relName
      });
    }, _addAggToHelper2 = function(sigKey, alias, aggFunc, aggExpr, caption) {
      const rec = lodHelpers[sigKey];
      if (!rec)
        return { alias, caption };
      const dedupKey = `${aggFunc}::${aggExpr}`;
      const ex = rec.aggsByExpr[dedupKey];
      if (ex)
        return { alias: ex.alias, caption: ex.caption };
      const calcId = sigmaShortId();
      rec.aggsByExpr[dedupKey] = { alias, aggFunc, aggExpr, calcId, caption };
      rec.element.columns.push({ id: calcId, formula: `[Custom SQL/${alias}]`, name: caption });
      rec.element.order.push(calcId);
      return { alias, caption };
    }, _finalizeHelpers2 = function() {
      const { fromClause, ctePrefix } = _baseFromExpr2();
      const useBase = fromClause === "__lod_base";
      for (const sigKey of Object.keys(lodHelpers)) {
        const rec = lodHelpers[sigKey];
        const dimList = useBase ? rec.groupDimDisplayNames.map((dn) => physToQuotedAlias[dn.replace(/\s+/g, "_").toUpperCase()] || `"${dn}"`).join(", ") : rec.groupDimNames.join(", ");
        const aggParts = [];
        for (const k of Object.keys(rec.aggsByExpr)) {
          const a = rec.aggsByExpr[k];
          const safeExpr = useBase ? rewriteBaseExpr(a.aggExpr) : a.aggExpr;
          let sqlAggFunc = a.aggFunc;
          if (sqlAggFunc === "COUNTD")
            sqlAggFunc = "COUNT(DISTINCT " + safeExpr + ")";
          else
            sqlAggFunc = `${sqlAggFunc}(${safeExpr})`;
          aggParts.push(`${sqlAggFunc} AS ${a.alias}`);
        }
        const groupByIdx = rec.groupDimNames.map((_d, i) => i + 1).join(", ");
        const withPrefix = ctePrefix ? `WITH ${ctePrefix.replace(/,\s*$/, "\n")}` : "";
        rec.element.source.statement = `${withPrefix}SELECT ${dimList}, ${aggParts.join(", ")} FROM ${fromClause} GROUP BY ${groupByIdx}`;
      }
    }, _emitTopNHelper2 = function(top) {
      const keyResolved = _resolveDimDisplayName2(top.dimField);
      if (!keyResolved || !keyResolved.baseColId) {
        warnings.push(`\u26A0 Set "${top.caption}": ranking key [${top.dimField}] not found on base; skipped.`);
        return false;
      }
      const partResolved = [];
      for (const p of top.partitionBy) {
        const r = _resolveDimDisplayName2(p);
        if (!r || !r.baseColId) {
          warnings.push(`\u26A0 Set "${top.caption}": partition dim [${p}] not found on base; skipped.`);
          return false;
        }
        partResolved.push(r);
      }
      let nLiteral;
      let controlId = null;
      if (top.count !== null) {
        nLiteral = String(top.count);
      } else if (top.countControl) {
        const param = parameters.find((p) => p.name.toUpperCase() === top.countControl.toUpperCase() || p.rawName?.toUpperCase() === top.countControl.toUpperCase() || sigmaDisplayName(p.name).toUpperCase() === sigmaDisplayName(top.countControl).toUpperCase());
        const ctlSourceName = param?.name || top.countControl;
        const cidBase = sigmaDisplayName(ctlSourceName).replace(/\s+/g, "-");
        controlId = cidBase;
        const defaultVal = parseInt(param?.defaultVal || "10", 10) || 10;
        if (param)
          topNParamControls[param.name] = { controlId: cidBase, defaultVal };
        topNParamControls[top.countControl] = { controlId: cidBase, defaultVal };
        nLiteral = `[${cidBase}]`;
      } else {
        warnings.push(`\u26A0 Set "${top.caption}": no count or count-control; skipped.`);
        return false;
      }
      const dirSql = top.direction === "bottom" ? "ASC" : "DESC";
      const aliasBase = _topNAlias(top.caption, topNUsedAliases);
      const helperId = sigmaShortId();
      const cols = [];
      const order = [];
      const keyColId = sigmaShortId();
      cols.push({ id: keyColId, formula: `[Custom SQL/${keyResolved.dimUpper}]`, name: keyResolved.displayName });
      order.push(keyColId);
      const partColIds = [];
      for (const p of partResolved) {
        const pid = sigmaShortId();
        cols.push({ id: pid, formula: `[Custom SQL/${p.dimUpper}]`, name: p.displayName });
        order.push(pid);
        partColIds.push(pid);
      }
      const totalColId = sigmaShortId();
      cols.push({ id: totalColId, formula: "[Custom SQL/TOTAL]", name: `${top.caption} Total` });
      order.push(totalColId);
      const rnkColId = sigmaShortId();
      cols.push({ id: rnkColId, formula: "[Custom SQL/RNK]", name: `${top.caption} Rank` });
      order.push(rnkColId);
      const isTopNColId = sigmaShortId();
      const isTopNName = `${top.caption} ${top.direction === "bottom" ? "Bottom" : "Top"} N`;
      const rankColName = `${top.caption} Rank`;
      let isTopNFormula;
      let emitIsTopNInSql = false;
      if (controlId) {
        isTopNFormula = `[${rankColName}] <= [${controlId}]`;
      } else {
        isTopNFormula = "[Custom SQL/IS_TOP_N]";
        emitIsTopNInSql = true;
      }
      cols.push({ id: isTopNColId, formula: isTopNFormula, name: isTopNName });
      order.push(isTopNColId);
      const fe = factEl;
      const { fromClause: topNFrom, ctePrefix: topNCtePrefix } = _baseFromExpr2();
      const topNUseBase = topNFrom === "__lod_base";
      const groupCols = [keyResolved.dimUpper, ...partResolved.map((p) => p.dimUpper)].map((c) => topNUseBase ? physToQuotedAlias[c] || c : c);
      const groupByIdx = groupCols.map((_g, i) => i + 1).join(", ");
      let aggSql = top.byAggFunc;
      const safeByField = topNUseBase ? rewriteBaseExpr(top.byField) : top.byField;
      if (aggSql === "COUNTD")
        aggSql = `COUNT(DISTINCT ${safeByField})`;
      else
        aggSql = `${aggSql}(${safeByField})`;
      const partBy = top.partitionBy.length > 0 ? `PARTITION BY ${top.partitionBy.join(", ")} ` : "";
      const overClause = `RANK() OVER (${partBy}ORDER BY s ${dirSql})`;
      const innerSelect = `SELECT ${groupCols.join(", ")}, ${aggSql} AS s FROM ${topNFrom} GROUP BY ${groupByIdx}`;
      const rankedSelect = `SELECT ${groupCols.join(", ")}, s, ${overClause} AS RNK FROM agg`;
      const outerCols = emitIsTopNInSql ? `${groupCols.join(", ")}, s AS TOTAL, RNK, (RNK <= ${nLiteral}) AS IS_TOP_N` : `${groupCols.join(", ")}, s AS TOTAL, RNK`;
      const outerSelect = `SELECT ${outerCols} FROM ranked`;
      const statement = topNCtePrefix ? `WITH ${topNCtePrefix}agg AS (${innerSelect}), ranked AS (${rankedSelect}) ${outerSelect}` : `WITH agg AS (${innerSelect}), ranked AS (${rankedSelect}) ${outerSelect}`;
      const helperEl = {
        id: helperId,
        kind: "table",
        // No element-level name field for kind:sql elements (per spec rule 3).
        source: { connectionId: connId, kind: "sql", statement },
        columns: cols,
        order
      };
      helperEl.name = `${top.caption} Top-N Helper`;
      const relName = `${factTableName}_TOPN_${aliasBase}`;
      if (!fe.relationships)
        fe.relationships = [];
      const relKeys = [
        { sourceColumnId: keyResolved.baseColId, targetColumnId: keyColId }
      ];
      for (let i = 0; i < partResolved.length; i++) {
        const baseColId = partResolved[i].baseColId;
        if (baseColId)
          relKeys.push({ sourceColumnId: baseColId, targetColumnId: partColIds[i] });
      }
      fe.relationships.push({
        id: sigmaShortId(),
        targetElementId: helperEl.id,
        keys: relKeys,
        name: relName
      });
      topNHelpers.push({
        element: helperEl,
        isTopNColId,
        relationshipName: relName,
        setNames: [top.setName, top.caption]
      });
      const idxEntry = {
        helperEl,
        relName,
        isTopNDisplayName: isTopNName,
        helperElName: helperEl.name,
        isTopNColId
      };
      topNSetIndex[top.setName.toUpperCase()] = idxEntry;
      topNSetIndex[top.caption.toUpperCase()] = idxEntry;
      warnings.push(`\u2705 Set "${top.caption}" (${top.direction.toUpperCase()}-${top.count !== null ? top.count : "[" + top.countControl + "]"}${top.partitionBy.length ? " per " + top.partitionBy.join(",") : ""}) \u2192 kind:sql RANK helper`);
      return true;
    }, _ensureWindowHelper2 = function(partitionDims, orderDimRaw, orderDimDateTrunc, relName) {
      const partKey = partitionDims.map((d) => d.dimUpper).slice().sort().join(",");
      const orderKey = orderDimRaw ? `${orderDimRaw}|${orderDimDateTrunc || ""}` : "";
      const key = partKey + "||" + orderKey;
      const existing = windowHelpers[key];
      if (existing)
        return { helper: existing.element, key, rec: existing };
      if (partitionDims.length === 0 && !orderDimRaw)
        return null;
      const helperId = sigmaShortId();
      const cols = [];
      const order = [];
      const partitionDimColIds = [];
      for (const d of partitionDims) {
        const colId = sigmaShortId();
        cols.push({ id: colId, formula: `[Custom SQL/${d.dimUpper}]`, name: d.displayName });
        order.push(colId);
        partitionDimColIds.push(colId);
      }
      let orderDimColId = null;
      let orderDimAlias = null;
      if (orderDimRaw) {
        orderDimAlias = orderDimDateTrunc ? `${orderDimRaw.replace(/_DATE$/, "")}_${orderDimDateTrunc.toUpperCase()}` : orderDimRaw;
        if (partitionDims.find((p) => p.dimUpper === orderDimAlias)) {
          orderDimAlias = `${orderDimAlias}_W`;
        }
        const oid = sigmaShortId();
        cols.push({
          id: oid,
          formula: `[Custom SQL/${orderDimAlias}]`,
          name: sigmaDisplayName(orderDimAlias)
        });
        order.push(oid);
        orderDimColId = oid;
      }
      const helperEl = {
        id: helperId,
        kind: "table",
        name: relName,
        source: { connectionId: connId, kind: "sql", statement: "__PLACEHOLDER__" },
        columns: cols,
        order
      };
      const rec = {
        element: helperEl,
        partitionDimNames: partitionDims.map((d) => d.dimUpper),
        orderDimRaw,
        orderDimAlias,
        orderDimDateTrunc,
        partitionDimColIds,
        orderDimColId,
        innerAggs: {},
        windowAliases: /* @__PURE__ */ new Set(),
        windowOverParts: [],
        relationshipName: relName
      };
      windowHelpers[key] = rec;
      windowChildElements.push(helperEl);
      const baseRels = factEl.relationships || [];
      const alreadyLinked = baseRels.find((r) => r.targetElementId === helperEl.id);
      if (!alreadyLinked && partitionDims.length > 0 && partitionDims.every((d) => d.baseColId)) {
        if (!factEl.relationships)
          factEl.relationships = [];
        const keys = [];
        for (let i = 0; i < partitionDims.length; i++) {
          keys.push({ sourceColumnId: partitionDims[i].baseColId, targetColumnId: partitionDimColIds[i] });
        }
        factEl.relationships.push({
          id: sigmaShortId(),
          targetElementId: helperEl.id,
          keys,
          name: relName
        });
      }
      return { helper: helperEl, key, rec };
    }, _registerInnerAgg2 = function(rec, aggFunc, exprSql) {
      const key = `${aggFunc}::${exprSql}`;
      if (rec.innerAggs[key])
        return rec.innerAggs[key].alias;
      const idMatch = exprSql.match(/[A-Z][A-Z0-9_]*/);
      let alias = idMatch ? idMatch[0] : "VAL";
      let n = 2;
      while (rec.windowAliases.has(alias) || Object.values(rec.innerAggs).some((v) => v.alias === alias)) {
        alias = idMatch ? `${idMatch[0]}_${n++}` : `VAL_${n++}`;
      }
      rec.innerAggs[key] = { alias };
      return alias;
    }, _emitWindowOverClause2 = function(rec, win, windowAlias, innerAlias) {
      const partBy = rec.partitionDimNames.length > 0 ? `PARTITION BY ${rec.partitionDimNames.join(", ")}` : "";
      const orderBy = rec.orderDimAlias ? `ORDER BY ${rec.orderDimAlias}` : "";
      const windowSpec = (parts) => parts.filter(Boolean).join(" ");
      let overSql = "";
      switch (win.windowType) {
        case "RUNNING_SUM":
        case "RUNNING_AVG":
        case "RUNNING_MIN":
        case "RUNNING_MAX": {
          if (!rec.orderDimAlias)
            return { ok: false, reason: "no order dim" };
          const fn = win.windowType.replace("RUNNING_", "");
          overSql = `${fn}(${innerAlias}) OVER (${windowSpec([partBy, orderBy])} ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`;
          break;
        }
        case "WINDOW_SUM":
        case "WINDOW_AVG":
        case "WINDOW_MIN":
        case "WINDOW_MAX":
        case "WINDOW_COUNT": {
          const fn = win.windowType.replace("WINDOW_", "");
          overSql = `${fn}(${innerAlias}) OVER (${partBy})`;
          break;
        }
        case "LOOKUP": {
          if (!rec.orderDimAlias)
            return { ok: false, reason: "no order dim" };
          const offset = win.lookupOffset ?? -1;
          const fn = offset < 0 ? "LAG" : offset > 0 ? "LEAD" : "";
          if (!fn) {
            overSql = `${innerAlias}`;
          } else {
            overSql = `${fn}(${innerAlias}, ${Math.abs(offset)}) OVER (${windowSpec([partBy, orderBy])})`;
          }
          break;
        }
        case "RANK":
        case "RANK_DENSE":
        case "RANK_UNIQUE": {
          let rankExpr = innerAlias;
          if (!rankExpr) {
            const firstInner = Object.values(rec.innerAggs)[0];
            if (firstInner)
              rankExpr = firstInner.alias;
            else
              return { ok: false, reason: "rank has no measure to order by" };
          }
          const dir = (win.rankDirection || "desc").toUpperCase();
          const rankFn = win.windowType === "RANK_DENSE" ? "DENSE_RANK" : win.windowType === "RANK_UNIQUE" ? "ROW_NUMBER" : "RANK";
          overSql = `${rankFn}() OVER (${windowSpec([partBy, `ORDER BY ${rankExpr} ${dir}`])})`;
          break;
        }
        case "INDEX": {
          if (!rec.orderDimAlias)
            return { ok: false, reason: "no order dim" };
          overSql = `ROW_NUMBER() OVER (${windowSpec([partBy, orderBy])})`;
          break;
        }
        case "FIRST": {
          if (!rec.orderDimAlias)
            return { ok: false, reason: "no order dim" };
          overSql = `(1 - ROW_NUMBER() OVER (${windowSpec([partBy, orderBy])}))`;
          break;
        }
        case "LAST": {
          if (!rec.orderDimAlias)
            return { ok: false, reason: "no order dim" };
          overSql = `(COUNT(*) OVER (${partBy}) - ROW_NUMBER() OVER (${windowSpec([partBy, orderBy])}))`;
          break;
        }
        default:
          return { ok: false, reason: "unsupported window type " + win.windowType };
      }
      rec.windowOverParts.push(`${overSql} AS ${windowAlias}`);
      rec.windowAliases.add(windowAlias);
      const calcId = sigmaShortId();
      rec.element.columns.push({ id: calcId, formula: `[Custom SQL/${windowAlias}]` });
      rec.element.order.push(calcId);
      return { ok: true };
    }, _finalizeWindowHelpers2 = function() {
      const { fromClause: winFrom, ctePrefix: winCtePrefix } = _baseFromExpr2();
      const winUseBase = winFrom === "__lod_base";
      for (const key of Object.keys(windowHelpers)) {
        const rec = windowHelpers[key];
        const selectParts = [];
        for (const d of rec.partitionDimNames) {
          selectParts.push(winUseBase ? physToQuotedAlias[d] || d : d);
        }
        if (rec.orderDimRaw && rec.orderDimAlias) {
          const rawRef = winUseBase ? rewriteBaseExpr(rec.orderDimRaw) : rec.orderDimRaw;
          if (rec.orderDimDateTrunc) {
            selectParts.push(`DATE_TRUNC('${rec.orderDimDateTrunc}', ${rawRef}) AS ${rec.orderDimAlias}`);
          } else {
            selectParts.push(`${rawRef} AS ${rec.orderDimAlias}`);
          }
        }
        for (const k of Object.keys(rec.innerAggs)) {
          const [aggFunc, exprSql] = k.split("::");
          const safeExpr = winUseBase ? rewriteBaseExpr(exprSql) : exprSql;
          const a = rec.innerAggs[k];
          let sqlFn = aggFunc;
          if (sqlFn === "COUNTD")
            sqlFn = `COUNT(DISTINCT ${safeExpr})`;
          else
            sqlFn = `${sqlFn}(${safeExpr})`;
          selectParts.push(`${sqlFn} AS ${a.alias}`);
        }
        const groupByCount = rec.partitionDimNames.length + (rec.orderDimRaw ? 1 : 0);
        const groupByIdx = Array.from({ length: groupByCount }, (_, i) => i + 1).join(", ");
        const baseSelect = `SELECT ${selectParts.join(", ")} FROM ${winFrom} GROUP BY ${groupByIdx}`;
        const innerProjection = [
          ...rec.partitionDimNames,
          ...rec.orderDimAlias ? [rec.orderDimAlias] : [],
          ...Object.values(rec.innerAggs).map((v) => v.alias)
        ];
        const outerProjection = innerProjection.concat(rec.windowOverParts);
        rec.element.source.statement = winCtePrefix ? `WITH ${winCtePrefix}base AS (${baseSelect}) SELECT ${outerProjection.join(", ")} FROM base` : `WITH base AS (${baseSelect}) SELECT ${outerProjection.join(", ")} FROM base`;
      }
    };
    var _baseFromExpr = _baseFromExpr2, _resolveDimDisplayName = _resolveDimDisplayName2, _ensureHelper = _ensureHelper2, _ensureRelationship = _ensureRelationship2, _addAggToHelper = _addAggToHelper2, _finalizeHelpers = _finalizeHelpers2, _emitTopNHelper = _emitTopNHelper2, _ensureWindowHelper = _ensureWindowHelper2, _registerInnerAgg = _registerInnerAgg2, _emitWindowOverClause = _emitWindowOverClause2, _finalizeWindowHelpers = _finalizeWindowHelpers2;
    const globalColMap = {};
    const displayNameMap = {};
    for (const el of elements) {
      for (const c of el.columns || []) {
        const fm = c.formula.match(/\/([^\]]+)\]$/);
        if (fm) {
          const dn = fm[1];
          globalColMap[dn.toUpperCase()] = { elId: el.id, displayName: dn };
          displayNameMap[dn.toUpperCase()] = { colId: c.id, el };
          displayNameMap[dn.replace(/\s+/g, "_").toUpperCase()] = { colId: c.id, el };
        }
        if (c.name)
          displayNameMap[c.name.toUpperCase()] = { colId: c.id, el };
      }
    }
    const factTableName = factEl.source?.path?.[factEl.source.path.length - 1] || "FACT";
    const physToQuotedAlias = {};
    if (factEl?.source?.kind === "sql") {
      for (const col of factEl?.columns || []) {
        const dn = col.name || "";
        if (!dn)
          continue;
        const physUpper = dn.replace(/\s+/g, "_").toUpperCase();
        physToQuotedAlias[physUpper] = `"${dn}"`;
        physToQuotedAlias[dn.toUpperCase()] = `"${dn}"`;
      }
    }
    const resolveBaseToken = (token) => physToQuotedAlias[token] || physToQuotedAlias[token.toUpperCase()] || token;
    const rewriteBaseExpr = (expr) => expr.replace(/\b([A-Z][A-Z0-9_]*)\b/g, (_m, tok) => resolveBaseToken(tok));
    const lodChildElements = [];
    const wsIndex = _buildWorksheetIndex(parsed);
    const lodHelpers = {};
    const usedAliases = /* @__PURE__ */ new Set();
    const topNHelpers = [];
    const topNUsedAliases = /* @__PURE__ */ new Set();
    const topNSetIndex = {};
    const windowWsIndex = _buildWindowWorksheetIndex(parsed);
    const windowHelpers = {};
    const windowUsedAliases = /* @__PURE__ */ new Set();
    const windowChildElements = [];
    for (const col of asArray(ds.ds?.column || [])) {
      const rawName = attr(col, "name") || "";
      let caption = attr(col, "caption") || rawName.replace(/^\[|\]$/g, "");
      const hidden = attr(col, "hidden") === "true";
      const calcEl = col.calculation;
      const formula = calcEl ? rewriteGuidRefs(attr(calcEl, "formula") || "") : "";
      const fieldKey = rawName.replace(/^\[|\]$/g, "");
      const colDatatype = attr(col, "datatype") || "";
      if (hidden || !fieldKey || fieldKey.startsWith("Number of Records") || fieldKey.includes("__tableau_internal_object_id__") || colDatatype === "table" || /\(group\)\s*$/i.test(fieldKey) || /\(bin\)\s*$/i.test(fieldKey))
        continue;
      const guidMatch = (fieldKey.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
      if (factRelName && !formula) {
        const flattenSuffix = /\s\([^()]*\([^)]*\)\)\s*$/.test(caption);
        if (guidMatch) {
          if (derivedRelColGuids.has(guidMatch.toLowerCase()))
            continue;
          const owner = guidOwnerRel[guidMatch.toLowerCase()];
          const cap = guidCaption[guidMatch.toLowerCase()];
          if (owner && owner !== factRelName || flattenSuffix)
            continue;
          if (cap)
            caption = cap.trim();
        } else if (flattenSuffix) {
          continue;
        }
      }
      if (calcEl && attr(calcEl, "class") === "categorical-set") {
        const topN = tableauParseTopNSet(calcEl, caption, fieldKey);
        if (topN) {
          _emitTopNHelper2(topN);
          continue;
        }
        const setFormula = (attr(calcEl, "formula") || "").trim();
        let sigmaSetFormula = null;
        if (setFormula) {
          sigmaSetFormula = tableauFormulaToSigma(setFormula, warnings);
        } else {
          const memberFilters = [];
          const collectMembers = (node) => {
            if (!node || typeof node !== "object")
              return;
            for (const k of Object.keys(node)) {
              if (k === "groupfilter") {
                for (const gf of asArray(node[k])) {
                  if (attr(gf, "function") === "member")
                    memberFilters.push(gf);
                  collectMembers(gf);
                }
              } else if (typeof node[k] === "object") {
                collectMembers(node[k]);
              }
            }
          };
          collectMembers(calcEl);
          if (memberFilters.length > 0) {
            const membersByField = {};
            for (const gf of memberFilters) {
              const level = (attr(gf, "level") || "").replace(/^\[|\]$/g, "");
              const val = (attr(gf, "member") || "").replace(/^"|"$/g, "");
              if (!level || !val)
                continue;
              (membersByField[level] || (membersByField[level] = [])).push(val);
            }
            const conditions = Object.entries(membersByField).map(([f, vals]) => {
              const dn = sigmaDisplayName(f);
              return vals.length === 1 ? `[${dn}] = "${vals[0]}"` : vals.map((v) => `[${dn}] = "${v}"`).map((c) => `(${c})`).join(" Or ");
            });
            sigmaSetFormula = conditions.length === 1 ? conditions[0] : conditions.map((c) => `(${c})`).join(" And ");
          }
        }
        if (!sigmaSetFormula) {
          warnings.push(`\u26A0 Set "${caption}": unrecognised set definition \u2014 skipped.`);
          continue;
        }
        const _setColId = sigmaShortId();
        const _setFmt = inferSigmaFormat(String(sigmaSetFormula), caption);
        const _setCol = { id: _setColId, formula: String(sigmaSetFormula), name: caption };
        if (_setFmt)
          _setCol.format = _setFmt;
        factEl.columns.push(_setCol);
        factEl.order.push(_setColId);
        displayNameMap[caption.toUpperCase()] = { colId: _setColId, el: factEl };
        globalColMap[caption.toUpperCase()] = { elId: factEl.id, displayName: caption };
        warnings.push(`\u2705 Set "${caption}" \u2192 boolean column: ${String(sigmaSetFormula).slice(0, 80)}`);
        continue;
      }
      if (!formula) {
        const physCol = normalizeColumnName(fieldKey);
        const displayName = caption || sigmaDisplayName(physCol);
        if (!displayNameMap[displayName.toUpperCase()] && !displayNameMap[physCol]) {
          if (factEl.source?.kind === "sql")
            continue;
          const colId = sigmaInodeId(physCol);
          factEl.columns.push({ id: colId, formula: `[${factTableName}/${displayName}]` });
          factEl.order.push(colId);
          displayNameMap[displayName.toUpperCase()] = { colId, el: factEl };
          displayNameMap[physCol] = { colId, el: factEl };
          globalColMap[displayName.toUpperCase()] = { elId: factEl.id, displayName };
          const role = attr(col, "role") || "";
          const dataType = attr(col, "datatype") || "";
          const isNumeric = dataType === "real" || dataType === "integer" || dataType === "decimal";
          if (role === "measure" && isNumeric) {
            if (!factEl.metrics)
              factEl.metrics = [];
            const _autoFmt = inferSigmaFormat(`Sum([${displayName}])`, displayName);
            const _autoMetric = { id: sigmaShortId(), formula: `Sum([${displayName}])`, name: displayName };
            if (_autoFmt)
              _autoMetric.format = _autoFmt;
            factEl.metrics.push(_autoMetric);
          }
        }
        continue;
      }
      {
        const lod = tableauParseLOD(formula);
        if (lod) {
          const lodDimsResolved = [];
          let allFound = true;
          let dimOffFact = false;
          for (const dimName of lod.dims) {
            const r = _resolveDimDisplayName2(dimName);
            if (r) {
              lodDimsResolved.push(r);
              if (r.onFact === false)
                dimOffFact = true;
            } else {
              allFound = false;
              warnings.push(`\u26A0 LOD "${caption}" dim [${dimName}] not found`);
            }
          }
          if (dimOffFact) {
            warnings.push(`\u26A0 LOD "${caption}" (${lod.lodType}) groups by a dimension-table column (cross-table grain); not mechanizable as a single-table helper \u2014 needs manual Sigma authoring. Skipped.`);
            continue;
          }
          const fieldKeyUpper = fieldKey.toUpperCase();
          const viewContexts = wsIndex.byField.get(fieldKeyUpper) || [];
          const viewDimSets = viewContexts.length > 0 ? viewContexts.map((c) => c.dims.slice()) : [[]];
          const effectiveSets = [];
          const seenSigs = /* @__PURE__ */ new Set();
          for (const viewDims of viewDimSets) {
            let effective;
            if (lod.lodType === "FIXED") {
              effective = lodDimsResolved.map((d) => d.dimUpper);
            } else if (lod.lodType === "INCLUDE") {
              const set = new Set(viewDims);
              for (const d of lodDimsResolved)
                set.add(d.dimUpper);
              effective = Array.from(set);
            } else {
              const exclude = new Set(lodDimsResolved.map((d) => d.dimUpper));
              effective = viewDims.filter((v) => !exclude.has(v));
            }
            const sig = effective.slice().sort().join(",");
            if (sig && !seenSigs.has(sig)) {
              seenSigs.add(sig);
              effectiveSets.push(effective);
            }
          }
          if (lod.lodType === "FIXED" && lod.dims.length === 0) {
            if (!factEl.metrics)
              factEl.metrics = [];
            factEl.metrics.push({ id: sigmaShortId(), formula: lod.sigmaAgg, name: caption });
            warnings.push(`\u2705 LOD "${caption}" (table-scoped FIXED) \u2192 metric: ${lod.sigmaAgg}`);
            continue;
          }
          if (!allFound)
            continue;
          if (effectiveSets.length === 0) {
            warnings.push(`\u26A0 LOD "${caption}" (${lod.lodType}) \u2014 no view context found and dims empty; skipped.`);
            continue;
          }
          for (const effective of effectiveSets) {
            const dimResolved = [];
            let ok = true;
            for (const dn of effective) {
              const m = _resolveDimDisplayName2(dn);
              if (!m) {
                ok = false;
                warnings.push(`\u26A0 LOD "${caption}" view dim [${dn}] not found on base`);
                break;
              }
              dimResolved.push(m);
            }
            if (!ok)
              continue;
            const alias = _lodAlias(caption, usedAliases);
            const relName = `${lod.lodType} ${lod.dims.join(", ") || "(table)"}` + (effectiveSets.length > 1 ? ` @ ${effective.join("\xD7")}` : "");
            const helperRes = _ensureHelper2(effective, dimResolved, `${factTableName} ${lod.lodType} ${effective.join(", ")}`);
            if (!helperRes)
              continue;
            _ensureRelationship2(helperRes.signatureKey, dimResolved, relName);
            _addAggToHelper2(helperRes.signatureKey, alias, lod.aggFunc, lod.aggExpr, caption);
            warnings.push(`\u2705 LOD "${caption}" (${lod.lodType}) \u2192 helper "${helperRes.helper.name}" alias ${alias}`);
          }
          continue;
        }
        const win = tableauParseWindow(formula);
        if (win) {
          const fieldKeyUpper = fieldKey.toUpperCase();
          let ctxList = windowWsIndex.byField.get(fieldKeyUpper) || [];
          if (ctxList.length === 0) {
            const all = [];
            for (const v of windowWsIndex.byField.values()) {
              for (const c of v)
                all.push(c);
            }
            ctxList = all;
          }
          let chosen = null;
          for (const c of ctxList) {
            if (c.rowsDims.length > 0 && c.dateDim) {
              chosen = c;
              break;
            }
          }
          if (!chosen)
            for (const c of ctxList) {
              if (c.rowsDims.length > 0) {
                chosen = c;
                break;
              }
            }
          if (!chosen && ctxList.length > 0)
            chosen = ctxList[0];
          let partitionDimNames = chosen ? chosen.rowsDims.slice() : [];
          let orderDimRaw = chosen?.dateDim || null;
          let orderDimDateTrunc = chosen?.dateGrain ?? null;
          if (!chosen?.dateDim && chosen && chosen.colsDims.length > 0) {
            orderDimRaw = chosen.colsDims[0];
            orderDimDateTrunc = null;
          }
          const addressing = _parseWindowAddressing(calcEl);
          if (addressing) {
            if (addressing.mode === "specific" && addressing.orderFields.length > 0) {
              const orderSet = new Set(addressing.orderFields.map((s) => s.toUpperCase()));
              const allShelfDims = chosen ? Array.from(/* @__PURE__ */ new Set([...chosen.rowsDims, ...chosen.colsDims])) : [];
              partitionDimNames = allShelfDims.filter((d) => !orderSet.has(d.toUpperCase()));
              const firstOrder = addressing.orderFields[0];
              orderDimRaw = firstOrder;
              orderDimDateTrunc = chosen?.dateDim && firstOrder.toUpperCase() === chosen.dateDim.toUpperCase() ? chosen.dateGrain ?? null : null;
              warnings.push(`\u2705 Window calc "${caption}" \u2014 addressing override: order=[${addressing.orderFields.join(",")}], partition=[${partitionDimNames.join(",")}]`);
            } else if (addressing.mode === "table-across") {
            } else if (addressing.mode === "table-down") {
              partitionDimNames = chosen ? chosen.colsDims.slice() : [];
              orderDimRaw = chosen && chosen.rowsDims.length > 0 ? chosen.rowsDims[0] : null;
              orderDimDateTrunc = null;
            } else if (addressing.mode === "unknown") {
              warnings.push(`\u26A0 Window calc "${caption}" \u2014 Compute Using mode "${addressing.rawDirection}" is not yet supported; falling back to rows/cols heuristic`);
            }
          }
          const partitionResolved = [];
          let allP = true;
          for (const p of partitionDimNames) {
            const r = _resolveDimDisplayName2(p);
            if (!r) {
              allP = false;
              break;
            }
            partitionResolved.push(r);
          }
          if (!allP || partitionResolved.length === 0) {
            if (!_reportChartWindowPattern(caption, formula, "SQL window lowering failed (no partition dims resolved on base)")) {
              warnings.push(`\u26A0 Window calc "${caption}" \u2014 no partition dims resolved on base; skipped. Untranslated fragment: ${formula.trim().slice(0, 120)}`);
            }
            continue;
          }
          const relName = `Window ${partitionDimNames.join(", ")}` + (orderDimRaw ? ` ORDER ${orderDimRaw}${orderDimDateTrunc ? `(${orderDimDateTrunc})` : ""}` : "");
          const helperRes = _ensureWindowHelper2(partitionResolved, orderDimRaw, orderDimDateTrunc, relName);
          if (!helperRes) {
            warnings.push(`\u26A0 Window calc "${caption}" \u2014 could not create helper element; skipped`);
            continue;
          }
          let innerAlias = "";
          if (win.innerExprSql && win.innerAggFunc) {
            innerAlias = _registerInnerAgg2(helperRes.rec, win.innerAggFunc, win.innerExprSql);
          }
          const winAlias = _windowAlias(caption, windowUsedAliases);
          const emitRes = _emitWindowOverClause2(helperRes.rec, win, winAlias, innerAlias);
          if (!emitRes.ok) {
            if (!_reportChartWindowPattern(caption, formula, `SQL window lowering failed (${win.windowType}: ${emitRes.reason})`)) {
              warnings.push(`\u26A0 Window calc "${caption}" \u2192 ${win.windowType}: ${emitRes.reason}; skipped. Untranslated fragment: ${formula.trim().slice(0, 120)}`);
            }
            continue;
          }
          const lastCol = helperRes.rec.element.columns[helperRes.rec.element.columns.length - 1];
          if (lastCol && !lastCol.name)
            lastCol.name = caption;
          warnings.push(`\u2705 Window "${caption}" (${win.windowType}) \u2192 helper "${helperRes.rec.element.name}" alias ${winAlias}`);
          continue;
        }
        if (_reportChartWindowPattern(caption, formula, "no DM-safe SQL OVER lowering for this pattern"))
          continue;
        const paramRef = formula.match(/\[Parameters?\]\s*\.\s*\[([^\]]+)\]/i);
        if (paramRef) {
          const ctlId = paramControlId(paramRef[1]);
          const sw = tableauParamSwitchToSigma(formula, ctlId, warnings);
          if (sw) {
            workbookPatterns.push({
              kind: "param-switch",
              name: caption,
              source: formula.trim(),
              paramName: sw.paramName,
              controlId: ctlId,
              formula: sw.switchFormula,
              cases: sw.cases,
              elseExpr: sw.elseExpr,
              requires: "WORKBOOK element: a single-select list control + a Switch calc column on the master; charts referencing this calc plot the Switch column.",
              note: `Tableau parameter measure-picker \u2192 Sigma control-driven Switch. Build control [${ctlId}] (values from parameter "${sw.paramName}") and master calc ${caption} = ${sw.switchFormula.slice(0, 120)}.`
            });
            warnings.push(`\u{1F500} "${caption}" \u2192 control-driven Switch over [${ctlId}] (param "${sw.paramName}", ${sw.cases.length} case(s)) \u2014 reported in result.workbookPatterns for the workbook layer.`);
            continue;
          }
          workbookPatterns.push({
            kind: "param-filter",
            name: caption,
            source: formula.trim(),
            paramName: paramRef[1],
            controlId: ctlId,
            requires: "WORKBOOK control bound as a filter on the source element/table (not on a viz \u2014 control\u2192viz filters 400).",
            note: `Formula references Tableau parameter "${paramRef[1]}"; build a control [${ctlId}] and apply it as a filter on the master/source element.`
          });
          warnings.push(`\u2139 "${caption}" references Tableau parameter "${paramRef[1]}" \u2192 reported as a param-filter control [${ctlId}] for the workbook layer; NOT a DM column.`);
          continue;
        }
        const sigmaFormula = tableauFormulaToSigma(formula, warnings);
        if (!sigmaFormula || sigmaFormula.startsWith("/*"))
          continue;
        if (SIGMA_CHART_ONLY_WINDOW_RE.test(sigmaFormula) || formulaHasUntranslatableFragment(sigmaFormula)) {
          const clean = !formulaHasUntranslatableFragment(sigmaFormula);
          workbookPatterns.push({
            kind: clean ? "window" : "unsupported",
            name: caption,
            source: formula.trim(),
            ...clean ? { formula: sigmaFormula } : {},
            requires: "GROUPED workbook element (group by the chart/viz dimensions) \u2014 NOT valid as a DM calc column or metric",
            note: clean ? "Expression contains chart-context-only window functions \u2014 place in a grouped workbook element; not emitted as a DM column (window functions silently error there)." : `Table-calc fragment embedded in a larger expression \u2014 NOT fully translatable. Untranslated fragment: ${formula.trim().slice(0, 160)}`
          });
          warnings.push(clean ? `\u2139 "${caption}" \u2192 ${sigmaFormula} \u2014 CHART/grouped-element context only; reported in result.workbookPatterns, not emitted as a DM column.` : `\u26A0 "${caption}" embeds a table-calc fragment that could not be translated \u2014 NOT emitted as a DM column. Untranslated fragment: ${formula.trim().slice(0, 120)}`);
          continue;
        }
        if (tableauFormulaIsRls(formula)) {
          const rlsRefs = (sigmaFormula.match(/\[([^\]\/]+)\]/g) || []).map((r) => r.replace(/^\[|\]$/g, ""));
          const offFact = rlsRefs.find((n) => {
            if (/^(true|false|null)$/i.test(n))
              return false;
            const hit = displayNameMap[n.toUpperCase()] || displayNameMap[n.replace(/\s+/g, "_").toUpperCase()];
            return hit && hit.el !== factEl;
          });
          if (offFact) {
            warnings.push(`\u26A0 "${caption}" is row-level security but references a related-table column [${offFact}] (cross-element). Sigma RLS filters apply per-element \u2014 re-apply this rule on the element that owns [${offFact}] (or its derived view): add a boolean calc column ${sigmaFormula.slice(0, 70)} and an element filter keeping only True.`);
            continue;
          }
          const rlsName = /^RLS\b/i.test(caption) ? caption : `RLS: ${caption}`;
          security.push(makeRlsSecurity({ source: `Tableau calc "${caption}"`, element: factEl, name: rlsName, formula: sigmaFormula }));
          warnings.push(`\u{1F510} "${caption}" \u2192 row-level security DETECTED (reported in result.security, not injected): ${sigmaFormula.slice(0, 80)}. The migration skill provisions the referenced attribute(s)/team(s) and applies the RLS calc + filter.`);
          continue;
        }
        if (tableauIsAggregate(formula)) {
          const refNames = (sigmaFormula.match(/\[([^\]\/]+)\]/g) || []).map((r) => r.replace(/^\[|\]$/g, ""));
          const offFactRef = refNames.find((n) => {
            if (/^(true|false|null)$/i.test(n))
              return false;
            const hit = displayNameMap[n.toUpperCase()] || displayNameMap[n.replace(/\s+/g, "_").toUpperCase()];
            return hit && hit.el !== factEl;
          });
          if (offFactRef) {
            warnings.push(`\u26A0 Metric "${caption}" aggregates a dimension-table column [${offFactRef}] (cross-element); Sigma metrics can't reference related-element columns \u2014 needs manual authoring. Skipped.`);
            continue;
          }
          if (!factEl.metrics)
            factEl.metrics = [];
          const _mFmt = inferSigmaFormat(sigmaFormula, caption);
          const _m = { id: sigmaShortId(), formula: sigmaFormula, name: caption };
          if (_mFmt)
            _m.format = _mFmt;
          factEl.metrics.push(_m);
        } else {
          const colId = sigmaShortId();
          const _cFmt = inferSigmaFormat(sigmaFormula, caption);
          const _c = { id: colId, formula: sigmaFormula, name: caption };
          if (_cFmt)
            _c.format = _cFmt;
          factEl.columns.push(_c);
          factEl.order.push(colId);
          warnings.push(`\u2139 "${caption}" \u2192 calculated column. Review: ${sigmaFormula.slice(0, 60)}`);
        }
      }
    }
    {
      const normKey = (s) => s.replace(/[^a-zA-Z0-9]+/g, "").toLowerCase();
      const stripSuffix = (s) => s.replace(/\s*\([^()]*\)\s*$/, "").trim();
      const exactNames = /* @__PURE__ */ new Set();
      const normIndex = {};
      for (const c of factEl.columns || []) {
        if (!c.name)
          continue;
        exactNames.add(c.name.toLowerCase());
        const k = normKey(c.name);
        if (k && !(k in normIndex))
          normIndex[k] = c.name;
      }
      let rewrites = 0;
      const reconcile = (formula, ownName) => {
        if (typeof formula !== "string")
          return formula;
        return formula.replace(/\[([^\]]+)\]/g, (m, ref) => {
          if (ref.includes("/"))
            return m;
          if (ownName && ref.toLowerCase() === ownName.toLowerCase()) {
            const alt = normIndex[normKey(ref)];
            if (alt && alt.toLowerCase() !== ownName.toLowerCase()) {
              rewrites++;
              return `[${alt}]`;
            }
            return m;
          }
          if (exactNames.has(ref.toLowerCase()))
            return m;
          const hit = normIndex[normKey(ref)] || normIndex[normKey(stripSuffix(ref))];
          if (hit) {
            rewrites++;
            return `[${hit}]`;
          }
          return m;
        });
      };
      const isAliasFormula = (f) => typeof f === "string" && /^\[(Custom SQL|[^\]\/]+)\/[^\]]+\]$/.test(f);
      for (const c of factEl.columns || []) {
        if (isAliasFormula(c.formula))
          continue;
        c.formula = reconcile(c.formula, c.name);
      }
      for (const m of factEl.metrics || []) {
        m.formula = reconcile(m.formula, m.name);
      }
      if (rewrites > 0) {
        warnings.push(`\u2139 Reconciled ${rewrites} calc-formula field reference(s) to their SQL-alias column names (caption\u2194alias) on "${factEl.name}".`);
      }
      {
        const typeByName = {};
        for (const c of factEl.columns || []) {
          if (c.name && colTypeById[c.id])
            typeByName[c.name.toLowerCase()] = colTypeById[c.id];
        }
        const isTextRef = (name) => typeByName[name.toLowerCase()] === "string";
        for (const c of factEl.columns || []) {
          if (isAliasFormula(c.formula))
            continue;
          c.formula = tableauTextConcatToSigma(c.formula, isTextRef);
        }
        for (const m of factEl.metrics || [])
          m.formula = tableauTextConcatToSigma(m.formula, isTextRef);
      }
      {
        const before = (factEl.columns || []).length;
        factEl.columns = (factEl.columns || []).filter((c) => {
          const self = c.name && typeof c.formula === "string" && c.formula.trim().toLowerCase() === `[${c.name}]`.toLowerCase();
          if (self) {
            factEl.order = (factEl.order || []).filter((id) => id !== c.id);
          }
          return !self;
        });
        const n = before - factEl.columns.length;
        if (n)
          warnings.push(`\u2139 Dropped ${n} self-referential rename calc(s) on "${factEl.name}" (redundant \u2014 the physical column is already present).`);
      }
      {
        const metricNames = new Set((factEl.metrics || []).map((m) => (m.name || "").toLowerCase()));
        const validNames = /* @__PURE__ */ new Set();
        for (const c of factEl.columns || [])
          if (c.name)
            validNames.add(c.name.toLowerCase());
        for (const n of metricNames)
          validNames.add(n);
        const sib = (f) => typeof f === "string" ? (f.match(/\[([^\]]+)\]/g) || []).map((s) => s.slice(1, -1)).filter((r) => !r.includes("/")) : [];
        const isDimLike = (f) => {
          if (typeof f !== "string")
            return false;
          const s = f.trim();
          if (/^(If|Iif|Case|Switch)\b/i.test(s) && /"[^"]*"/.test(s))
            return true;
          if (/^\[[^\]]+\]\s*(<=|>=|<>|!=|<|>|=)\s*-?[\d.]+\s*$/.test(s))
            return true;
          return false;
        };
        let promoted = 0, aggDims = 0, moved = true;
        while (moved) {
          moved = false;
          for (let i = (factEl.columns || []).length - 1; i >= 0; i--) {
            const c = factEl.columns[i];
            if (isAliasFormula(c.formula))
              continue;
            const refs = sib(c.formula);
            if (refs.length && refs.every((r) => validNames.has(r.toLowerCase())) && refs.some((r) => metricNames.has(r.toLowerCase()))) {
              if (isDimLike(c.formula)) {
                const aggRefs = refs.filter((r) => metricNames.has(r.toLowerCase()));
                workbookPatterns.push({
                  kind: "aggregate-dimension",
                  name: c.name,
                  source: c.formula,
                  formula: c.formula,
                  requires: "GROUPED workbook element: bucket the referenced aggregate metric(s) at the chart grain in the grouping context \u2014 NOT valid as a DM column or as a metric (a metric cannot be a grouping dimension).",
                  note: `Aggregate-derived dimension: buckets aggregate metric(s) [${aggRefs.join("], [")}]. Group the chart by this binned aggregate (compute the metric at the viz grain, then bucket); the DM cannot express it row-level.`
                });
                factEl.columns.splice(i, 1);
                factEl.order = (factEl.order || []).filter((id) => id !== c.id);
                aggDims++;
                moved = true;
                continue;
              }
              if (!factEl.metrics)
                factEl.metrics = [];
              factEl.metrics.push({ id: c.id, formula: c.formula, name: c.name, ...c.format ? { format: c.format } : {} });
              metricNames.add((c.name || "").toLowerCase());
              factEl.columns.splice(i, 1);
              factEl.order = (factEl.order || []).filter((id) => id !== c.id);
              promoted++;
              moved = true;
            }
          }
        }
        if (promoted)
          warnings.push(`\u2139 Promoted ${promoted} aggregate-ratio calc column(s) to metrics on "${factEl.name}" (they reference aggregate metrics \u2014 invalid as row-level columns).`);
        if (aggDims)
          warnings.push(`\u2139 "${factEl.name}": ${aggDims} aggregate-derived dimension(s) (bucket an aggregate metric) \u2192 reported in result.workbookPatterns \u2014 CHART/grouped-element context only; group the viz by the binned aggregate (NOT a DM column or metric).`);
      }
      const valid = /* @__PURE__ */ new Set();
      for (const c of factEl.columns || [])
        if (c.name)
          valid.add(c.name.toLowerCase());
      for (const mt of factEl.metrics || [])
        if (mt.name)
          valid.add(mt.name.toLowerCase());
      const siblingRefs = (f) => typeof f === "string" ? (f.match(/\[([^\]]+)\]/g) || []).map((s) => s.slice(1, -1)).filter((r) => !r.includes("/")) : [];
      const dropped = [];
      let changed = true;
      while (changed) {
        changed = false;
        const dropCol = (arr, isMetric) => {
          for (let i = arr.length - 1; i >= 0; i--) {
            const c = arr[i];
            if (!isMetric && isAliasFormula(c.formula))
              continue;
            const bad = siblingRefs(c.formula).find((r) => !valid.has(r.toLowerCase()));
            if (bad) {
              dropped.push({ name: c.name || "(unnamed)", bad });
              if (c.name)
                valid.delete(c.name.toLowerCase());
              if (!isMetric)
                factEl.order = (factEl.order || []).filter((id) => id !== c.id);
              arr.splice(i, 1);
              changed = true;
            }
          }
        };
        dropCol(factEl.columns || [], false);
        if (factEl.metrics)
          dropCol(factEl.metrics, true);
      }
      for (const d of dropped) {
        warnings.push(`\u26A0 Dropped calc "${d.name}" \u2014 references [${d.bad}] which is not a resolvable column in the collapsed model (param-driven or field absent from the SQL). NOT migrated; recreate in the workbook layer if needed.`);
      }
      if (dropped.length) {
        warnings.push(`\u2139 Dropped ${dropped.length} unresolvable calc column(s)/metric(s) on "${factEl.name}" after caption\u2194alias reconciliation (see per-calc warnings above).`);
      }
    }
    _finalizeHelpers2();
    _finalizeWindowHelpers2();
    for (const child of windowChildElements) {
      elements.push(child);
    }
    if (windowChildElements.length > 0) {
      warnings.push(`\u2139 ${windowChildElements.length} window helper element(s) created (kind:sql)`);
    }
    for (const child of lodChildElements) {
      delete child._dimKey;
      elements.push(child);
    }
    if (lodChildElements.length > 0) {
      warnings.push(`\u2139 ${lodChildElements.length} LOD helper element(s) created`);
    }
    for (const rec of topNHelpers) {
      elements.push(rec.element);
    }
    if (topNHelpers.length > 0) {
      warnings.push(`\u2139 ${topNHelpers.length} Top-N helper element(s) created (kind:sql)`);
    }
  }
  const crossElCalcsByElId = {};
  for (const el of elements) {
    if (el.source?.kind !== "warehouse-table")
      continue;
    if (!el.relationships?.length)
      continue;
    const localNames = /* @__PURE__ */ new Set();
    for (const c of el.columns || []) {
      if (!c.formula)
        continue;
      const m = c.formula.match(/^\[[^\]\/]+\/([^\]]+)\]$/);
      if (m)
        localNames.add(m[1].toUpperCase());
      if (c.name)
        localNames.add(c.name.toUpperCase());
    }
    const crossEl = [];
    const keep = [];
    for (const c of el.columns || []) {
      if (!c.name || !c.formula) {
        keep.push(c);
        continue;
      }
      if (/^\[[^\]\/]+\/[^\]]+\]$/.test(c.formula)) {
        keep.push(c);
        continue;
      }
      const refs = c.formula.match(/\[([^\]\/]+)\]/g) || [];
      const hasCross = refs.some((ref) => {
        const n = ref.replace(/^\[|\]$/g, "");
        return !/^(true|false|null)$/i.test(n) && !localNames.has(n.toUpperCase());
      });
      if (hasCross) {
        const oi = (el.order || []).indexOf(c.id);
        if (oi >= 0)
          el.order.splice(oi, 1);
        crossEl.push(c);
      } else {
        keep.push(c);
      }
    }
    el.columns = keep;
    if (crossEl.length)
      crossElCalcsByElId[el.id] = crossEl;
  }
  const controls = [];
  for (const p of parameters) {
    const controlId = sigmaDisplayName(p.name).replace(/\s+/g, "-");
    if (topNParamControls[p.name]) {
      const def = topNParamControls[p.name];
      const defVal = parseInt(p.defaultVal || String(def.defaultVal), 10) || def.defaultVal;
      controls.push({
        kind: "control",
        controlId: def.controlId,
        id: sigmaShortId() + "con",
        controlType: "number",
        mode: "<=",
        value: defVal,
        includeNulls: "when-no-value-is-selected"
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 number control (Top-N driver, default ${defVal})`);
      continue;
    }
    if (p.domainType === "list" && p.members.length > 0) {
      controls.push({
        kind: "control",
        controlId,
        id: sigmaShortId() + "con",
        controlType: "list",
        mode: "include",
        selectionMode: "single",
        values: [],
        source: { kind: "manual", valueType: "text", values: p.members }
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 list control`);
    } else if (p.type === "date" || p.type === "datetime") {
      controls.push({
        kind: "control",
        controlId,
        id: sigmaShortId() + "con",
        controlType: "date-range",
        mode: "last",
        value: 90,
        unit: "day",
        includeToday: true
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 date-range control (default: last 90 days \u2014 adjust in Sigma UI)`);
    } else if (p.type === "real" || p.type === "integer" || p.domainType === "range") {
      controls.push({
        kind: "control",
        controlId,
        id: sigmaShortId() + "con",
        controlType: "number-range"
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 number-range control`);
    } else {
      controls.push({
        kind: "control",
        controlId,
        id: sigmaShortId() + "con",
        controlType: "text",
        mode: "contains"
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 text control`);
    }
  }
  const derivedEls = buildDerivedElements(elements);
  for (const de of derivedEls)
    elements.push(de);
  const placedSrcElIds = {};
  for (const de of derivedEls) {
    if (de.source?.kind !== "table" || !de.source.elementId)
      continue;
    const srcElId = de.source.elementId;
    const calcs = crossElCalcsByElId[srcElId];
    if (!calcs?.length)
      continue;
    const srcEl = elements.find((e) => e.id === srcElId);
    if (!srcEl)
      continue;
    const srcBaseName = srcEl.name || srcEl.source?.path?.[srcEl.source.path.length - 1] || "";
    const relatedNameMap = {};
    if (srcEl && srcEl.relationships && srcBaseName) {
      for (const rel of srcEl.relationships || []) {
        if (!rel.name)
          continue;
        const tgtEl = elements.find((e) => e.id === rel.targetElementId);
        if (!tgtEl || tgtEl.source?.kind !== "warehouse-table")
          continue;
        for (const tc of tgtEl.columns || []) {
          if (!tc.formula || tc.formula.startsWith("/*"))
            continue;
          const fm = tc.formula.match(/^\[([^\]]+)\]$/);
          if (!fm)
            continue;
          const inner = fm[1];
          const s = inner.lastIndexOf("/");
          const dispName = s >= 0 ? inner.slice(s + 1) : inner;
          if (!(dispName in relatedNameMap)) {
            relatedNameMap[dispName] = `${srcBaseName}/${rel.name}/${dispName}`;
          }
        }
      }
    }
    for (const c of calcs) {
      if (c.formula && Object.keys(relatedNameMap).length) {
        c.formula = c.formula.replace(/\[([^\]\/]+)\]/g, (match, refName) => {
          const rewritten = relatedNameMap[refName];
          return rewritten ? `[${rewritten}]` : match;
        });
      }
      de.columns.push(c);
      de.order.push(c.id);
    }
    warnings.push(`\u2139 ${calcs.length} calc col(s) moved to derived "${de.name}" (cross-element refs)`);
    placedSrcElIds[srcElId] = true;
  }
  for (const elId of Object.keys(crossElCalcsByElId)) {
    if (placedSrcElIds[elId])
      continue;
    for (const c of crossElCalcsByElId[elId]) {
      warnings.push(`\u26A0 "${c.name}" cross-element refs but no derived element \u2014 column dropped`);
    }
  }
  if (!connectionId)
    warnings.unshift("\u26A0 Connection ID not set \u2014 update in JSON before saving to Sigma");
  const sigmaModel = {
    name: ds.name,
    schemaVersion: 1,
    pages: [{ id: sigmaShortId(), name: "Page 1", elements: [...controls, ...elements] }]
  };
  const totalCols = elements.reduce((s, e) => s + (e.columns?.length || 0), 0);
  const totalMetrics = elements.reduce((s, e) => s + (e.metrics?.length || 0), 0);
  const totalRels = elements.reduce((s, e) => s + (e.relationships?.length || 0), 0);
  return {
    model: sigmaModel,
    warnings,
    ...security.length ? { security } : {},
    ...workbookPatterns.length ? { workbookPatterns } : {},
    ...parameters.length ? { parameters } : {},
    stats: {
      datasources: datasources.length,
      elements: elements.length,
      columns: totalCols,
      metrics: totalMetrics,
      relationships: totalRels,
      controls: controls.length,
      parameters: parameters.length,
      lodChildElements: elements.filter((e) => e.source?.kind === "table" && e.source?.elementId).length
    }
  };
}
export {
  collapseCustomSqlBlend,
  convertTableauToSigma
};
