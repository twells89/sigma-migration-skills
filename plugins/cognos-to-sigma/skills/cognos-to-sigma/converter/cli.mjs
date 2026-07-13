#!/usr/bin/env node
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

// converter/node_modules/fast-xml-parser/src/util.js
var require_util = __commonJS({
  "converter/node_modules/fast-xml-parser/src/util.js"(exports) {
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

// converter/node_modules/fast-xml-parser/src/validator.js
var require_validator = __commonJS({
  "converter/node_modules/fast-xml-parser/src/validator.js"(exports) {
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

// converter/node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js
var require_OptionsBuilder = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js"(exports) {
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

// converter/node_modules/fast-xml-parser/src/xmlparser/xmlNode.js
var require_xmlNode = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlparser/xmlNode.js"(exports, module) {
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

// converter/node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js
var require_DocTypeReader = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js"(exports, module) {
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

// converter/node_modules/strnum/strnum.js
var require_strnum = __commonJS({
  "converter/node_modules/strnum/strnum.js"(exports, module) {
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

// converter/node_modules/fast-xml-parser/src/ignoreAttributes.js
var require_ignoreAttributes = __commonJS({
  "converter/node_modules/fast-xml-parser/src/ignoreAttributes.js"(exports, module) {
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

// converter/node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js
var require_OrderedObjParser = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js"(exports, module) {
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

// converter/node_modules/fast-xml-parser/src/xmlparser/node2json.js
var require_node2json = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlparser/node2json.js"(exports) {
    "use strict";
    function prettify(node, options) {
      return compress(node, options);
    }
    function compress(arr3, options, jPath) {
      let text;
      const compressedObj = {};
      for (let i = 0; i < arr3.length; i++) {
        const tagObj = arr3[i];
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

// converter/node_modules/fast-xml-parser/src/xmlparser/XMLParser.js
var require_XMLParser = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlparser/XMLParser.js"(exports, module) {
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

// converter/node_modules/fast-xml-parser/src/xmlbuilder/orderedJs2Xml.js
var require_orderedJs2Xml = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlbuilder/orderedJs2Xml.js"(exports, module) {
    var EOL = "\n";
    function toXml(jArray, options) {
      let indentation = "";
      if (options.format && options.indentBy.length > 0) {
        indentation = EOL;
      }
      return arrToStr(jArray, options, "", indentation);
    }
    function arrToStr(arr3, options, jPath, indentation) {
      let xmlStr = "";
      let isPreviousElementTag = false;
      if (!Array.isArray(arr3)) {
        if (arr3 !== void 0 && arr3 !== null) {
          let text = arr3.toString();
          text = replaceEntitiesValue(text, options);
          return text;
        }
        return "";
      }
      for (let i = 0; i < arr3.length; i++) {
        const tagObj = arr3[i];
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
        for (let attr in attrMap) {
          if (!Object.prototype.hasOwnProperty.call(attrMap, attr)) continue;
          let attrVal = options.attributeValueProcessor(attr, attrMap[attr]);
          attrVal = replaceEntitiesValue(attrVal, options);
          if (attrVal === true && options.suppressBooleanAttributes) {
            attrStr += ` ${attr.substr(options.attributeNamePrefix.length)}`;
          } else {
            attrStr += ` ${attr.substr(options.attributeNamePrefix.length)}="${attrVal}"`;
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

// converter/node_modules/fast-xml-parser/src/xmlbuilder/json2xml.js
var require_json2xml = __commonJS({
  "converter/node_modules/fast-xml-parser/src/xmlbuilder/json2xml.js"(exports, module) {
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
          const attr = this.isAttribute(key);
          if (attr && !this.ignoreAttributesFn(attr, jPath)) {
            attrStr += this.buildAttrPairStr(attr, "" + jObj[key]);
          } else if (!attr) {
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

// converter/node_modules/fast-xml-parser/src/fxp.js
var require_fxp = __commonJS({
  "converter/node_modules/fast-xml-parser/src/fxp.js"(exports, module) {
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

// converter/cli.ts
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// converter/sigma-ids.ts
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
    id = Array.from(
      { length: len },
      () => SIGMA_CHARS[Math.floor(Math.random() * SIGMA_CHARS.length)]
    ).join("");
  } while (_usedIds.has(id));
  _usedIds.add(id);
  return id;
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s]+/).filter(Boolean);
  return words.map(
    (w, i) => i === 0 || !SIGMA_LOWERCASE_WORDS.has(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w
  ).join(" ");
}
function formatFromMask(mask) {
  if (!mask || typeof mask !== "string") return null;
  const s = mask.trim();
  if (!s || /general|date|time|@|yy|dd/i.test(s)) return null;
  const decM = s.match(/\.([0#]+)/);
  const decimals = decM ? decM[1].length : 0;
  const isPercent = /%/.test(s);
  const isCurrency = /[$£€¥]/.test(s);
  if (isPercent) return { kind: "number", formatString: `,.${decimals}%` };
  if (isCurrency) return { kind: "number", formatString: `$,.${decimals}f`, currencySymbol: "$" };
  if (/[0#]/.test(s)) return { kind: "number", formatString: `,.${decimals}f` };
  return null;
}
function inferSigmaFormat(formula, displayName, sourceMask) {
  const fromMask = formatFromMask(sourceMask);
  if (fromMask) return fromMask;
  if (!formula) return null;
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
function buildDerivedElements(elements) {
  const derived = [];
  for (const srcEl of elements) {
    if (!srcEl.relationships?.length) continue;
    if (srcEl.source?.kind !== "warehouse-table") continue;
    const srcPath = srcEl.source.path || [];
    const srcTableName = srcPath[srcPath.length - 1] || "";
    const baseName = srcEl.name || srcTableName;
    const derivedName = `${srcEl.name || sigmaDisplayName(srcTableName)} View`;
    const viewCols = [];
    const viewOrder = [];
    for (const col of srcEl.columns || []) {
      if (!col.formula || col.formula.startsWith("/*")) continue;
      const fm = col.formula.match(/^\[([^\/\]]+)\/([^\]]+)\]$/);
      if (!fm) continue;
      const dispName = fm[2];
      if (dispName.includes("/")) continue;
      const cId = sigmaShortId();
      viewCols.push({ id: cId, formula: `[${baseName}/${dispName}]` });
      viewOrder.push(cId);
    }
    for (const rel of srcEl.relationships) {
      if (!rel.name) continue;
      const tgtEl = elements.find((e) => e.id === rel.targetElementId);
      if (!tgtEl || tgtEl.source?.kind !== "warehouse-table") continue;
      for (const col of tgtEl.columns || []) {
        if (!col.formula || col.formula.startsWith("/*")) continue;
        const fm = col.formula.match(/^\[([^\]]+)\]$/);
        if (!fm) continue;
        const inner = fm[1];
        const s = inner.indexOf("/");
        const dispName = s >= 0 ? inner.slice(s + 1) : inner;
        if (dispName.includes("/")) continue;
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

// converter/cognos.ts
function applyLearnedRules(expr, rules) {
  let s = expr || "";
  for (const r of rules || []) {
    try {
      s = s.replace(new RegExp(r.pattern, r.flags || "gi"), r.template);
    } catch {
    }
  }
  return s;
}
var arr = (x) => Array.isArray(x) ? x : x == null ? [] : [x];
var lc = (s) => String(s ?? "").toLowerCase();
function normalizeCognosDataModule(input) {
  const root = typeof input === "string" ? JSON.parse(input) : input;
  const name = root.label || root.identifier || root.name || "Cognos Data Module";
  const querySubjects = [];
  const qsList = arr(root.querySubject || root.querySubjects || root.module?.querySubject);
  for (const qs of qsList) {
    const identifier = qs.identifier || qs.idForExpression || qs.label || "QUERY_SUBJECT";
    let table = identifier, database, schema;
    const ref0 = arr(qs.ref)[0];
    if (typeof ref0 === "string" && ref0.includes(".")) {
      table = ref0.split(".").slice(1).join(".");
    } else {
      const tableRef = arr(qs.definition?.dbQuery?.tableRef)[0] || qs.sourceTable || qs.table;
      const src = tableRef?.sourceTable || tableRef || {};
      table = src.name || (typeof tableRef === "string" ? tableRef : identifier);
      database = src.catalog || src.database || qs.catalog;
      schema = src.schema || qs.schema;
    }
    const items = [];
    for (const raw of arr(qs.item || qs.items)) {
      const qi = raw.queryItem || raw.calculation || raw.measure;
      if (!qi || !(qi.identifier || qi.label)) continue;
      const ident = qi.identifier || qi.label;
      const expr = qi.expression;
      const isCalc = !!raw.calculation || expr != null && !isPlainColumn(expr, identifier);
      items.push({
        identifier: ident,
        label: qi.label,
        expression: expr,
        datatype: qi.datatype || qi.highlevelDatatype,
        usage: lc(qi.usage),
        aggregate: lc(qi.regularAggregate || qi.aggregate || qi.aggregateFunction),
        isCalculation: isCalc
      });
    }
    querySubjects.push({ identifier, label: qs.label, database, schema, table, items });
  }
  const relationships = [];
  for (const rel of arr(root.relationship || root.relationships)) {
    const links = arr(rel.link);
    const left = qsKey(rel.left?.ref || links[0]?.ref || rel.left);
    const right = qsKey(rel.right?.ref || links[1]?.ref || rel.right);
    if (!left || !right) continue;
    const colLink = links.find((l) => l && (l.leftRef || l.rightRef));
    relationships.push({
      left,
      right,
      leftKey: colLink?.leftRef,
      rightKey: colLink?.rightRef,
      leftCard: lc(rel.left?.maxcard),
      rightCard: lc(rel.right?.maxcard),
      expression: rel.expression || rel.linkExpression,
      cardinality: rel.cardinality
    });
  }
  const securityFilters = [];
  const pushSec = (sf, subject) => {
    if (!sf || typeof sf !== "object") return;
    const groups = arr(sf.securityObject || sf.member || sf.members || sf.appliesTo).map((g) => typeof g === "string" ? g : g?.searchPath || g?.ref || g?.identifier).filter(Boolean);
    securityFilters.push({
      type: "data-module-security-filter",
      subject,
      name: sf.label || sf.identifier,
      expression: sf.expression || sf.filterDefinition || sf.embeddedFilter?.expression,
      ...groups.length ? { groups } : {}
    });
  };
  for (const sf of arr(root.securityFilter || root.securityFilters)) pushSec(sf);
  for (const qs of qsList) {
    for (const sf of arr(qs.securityFilter || qs.securityFilters)) pushSec(sf, qs.identifier || qs.label);
  }
  for (const fl of arr(root.filter || root.filters)) {
    if (fl && (lc(fl.classifier).includes("security") || arr(fl.propertyOverride).some((p) => lc(p).includes("security")))) pushSec(fl);
  }
  return { name, querySubjects, relationships, securityFilters };
}
function qsKey(ref) {
  const parts = String(ref).replace(/[[\]]/g, "").split(".");
  return parts[parts.length - 1].trim();
}
function isPlainColumn(expr, subjectId) {
  const e = (expr || "").trim();
  if (/^[A-Za-z_][\w ]*$/.test(e)) return true;
  const m = e.replace(/[[\]\s]/g, "").match(/^([\w]+)\.([\w]+)$/);
  return !!m && m[1].toUpperCase() === subjectId.toUpperCase();
}
function convertCognosIR(model, options = {}) {
  resetIds();
  const { connectionId = "<CONNECTION_ID>", database: dbOverride = "", schema: schOverride = "", modelName } = options;
  const warnings = [];
  const ctxByKey = /* @__PURE__ */ new Map();
  for (const qs of model.querySubjects) {
    const key = qs.identifier.toUpperCase();
    const path = [];
    const db = dbOverride || qs.database || "";
    const sch = schOverride || qs.schema || "";
    if (db) path.push(db);
    if (sch) path.push(sch);
    const tableTail = (qs.table || qs.identifier).toUpperCase();
    path.push(tableTail);
    const element = {
      id: sigmaShortId(),
      kind: "table",
      name: sigmaDisplayName(qs.identifier),
      source: { connectionId, kind: "warehouse-table", path },
      columns: [],
      order: []
    };
    ctxByKey.set(key, { element, columns: [], metrics: [], order: [], colIdByName: /* @__PURE__ */ new Map(), tableTail });
  }
  const ensureRawCol = (ctx, _tableKey, ident, hidden = false) => {
    const disp = sigmaDisplayName(ident);
    const existing = ctx.colIdByName.get(disp);
    if (existing) return existing;
    const id = sigmaShortId();
    const col = { id, formula: `[${ctx.tableTail}/${disp}]` };
    if (hidden) col.hidden = true;
    ctx.columns.push(col);
    ctx.order.push(id);
    ctx.colIdByName.set(disp, id);
    return id;
  };
  for (const qs of model.querySubjects) {
    const key = qs.identifier.toUpperCase();
    const ctx = ctxByKey.get(key);
    for (const item of qs.items) {
      const dispName = sigmaDisplayName(item.label || item.identifier);
      const isMeasure = !item.isCalculation && (item.usage === "fact" || item.usage === "measure") && item.aggregate && item.aggregate !== "none";
      if (item.isCalculation && item.expression) {
        const { formula, warnings: w } = translateCognosExpr(applyLearnedRules(item.expression, options.learnedRules), qs, ensureRawCol, ctx);
        w.forEach((x) => warnings.push(`"${qs.identifier}.${item.identifier}": ${x}`));
        if (/\b(Sum|Avg|Count|Min|Max|.*Over)\(/.test(formula)) {
          const m = { id: sigmaShortId(), name: dispName, formula };
          const fmt = inferSigmaFormat(formula, dispName);
          if (fmt) m.format = fmt;
          ctx.metrics.push(m);
        } else {
          const id = sigmaShortId();
          ctx.columns.push({ id, name: dispName, formula });
          ctx.order.push(id);
        }
      } else if (isMeasure) {
        ensureRawCol(ctx, key, item.identifier);
        const agg = aggFn(item.aggregate, `[${sigmaDisplayName(item.identifier)}]`);
        const m = { id: sigmaShortId(), name: dispName, formula: agg };
        const fmt = inferSigmaFormat(agg, dispName);
        if (fmt) m.format = fmt;
        ctx.metrics.push(m);
      } else {
        const physDisp = sigmaDisplayName(item.identifier);
        const existing = ctx.colIdByName.get(physDisp);
        if (existing) {
          if (dispName !== physDisp) {
          }
          continue;
        }
        const id = sigmaShortId();
        const col = { id, formula: `[${ctx.tableTail}/${physDisp}]` };
        if (dispName !== physDisp) col.name = dispName;
        ctx.columns.push(col);
        ctx.order.push(id);
        ctx.colIdByName.set(physDisp, id);
      }
    }
  }
  for (const rel of model.relationships) {
    let leftTable = rel.left, rightTable = rel.right, leftCol = rel.leftKey, rightCol = rel.rightKey;
    if (!leftCol || !rightCol) {
      const parsed = parseJoinExpr(rel.expression);
      if (!parsed) {
        warnings.push(`Relationship ${rel.left}\u2192${rel.right}: no join columns and expression "${trunc(rel.expression)}" not a simple equi-join \u2014 add manually in Sigma.`);
        continue;
      }
      ({ leftTable, leftCol, rightTable, rightCol } = parsed);
    }
    const rightIsMany = /many|\bn\b|\*/.test(rel.rightCard || "");
    const leftIsMany = /many|\bn\b|\*/.test(rel.leftCard || "");
    if (rightIsMany && !leftIsMany) {
      [leftTable, leftCol, rightTable, rightCol] = [rightTable, rightCol, leftTable, leftCol];
    }
    const srcKey = leftTable.toUpperCase(), tgtKey = rightTable.toUpperCase();
    const srcCtx = ctxByKey.get(srcKey), tgtCtx = ctxByKey.get(tgtKey);
    if (!srcCtx || !tgtCtx) {
      warnings.push(`Relationship ${srcKey}\u2192${tgtKey}: a query subject is missing \u2014 relationship skipped.`);
      continue;
    }
    const srcColId = ensureRawCol(srcCtx, srcKey, leftCol, true);
    const tgtColId = ensureRawCol(tgtCtx, tgtKey, rightCol, true);
    (srcCtx.element.relationships ||= []).push({
      id: sigmaShortId(),
      targetElementId: tgtCtx.element.id,
      keys: [{ sourceColumnId: srcColId, targetColumnId: tgtColId }],
      name: tgtKey
    });
  }
  const elements = [];
  for (const ctx of ctxByKey.values()) {
    ctx.element.columns = ctx.columns;
    ctx.element.order = ctx.order;
    if (ctx.metrics.length) ctx.element.metrics = ctx.metrics;
    elements.push(ctx.element);
  }
  for (const de of buildDerivedElements(elements)) elements.push(de);
  const stats = {
    querySubjects: model.querySubjects.length,
    elements: elements.length,
    columns: elements.reduce((n, e) => n + (e.columns?.length || 0), 0),
    metrics: elements.reduce((n, e) => n + (e.metrics?.length || 0), 0),
    relationships: elements.reduce((n, e) => n + (e.relationships?.length || 0), 0)
  };
  const security2 = (model.securityFilters || []).map((sf) => ({ ...sf }));
  if (security2.length) {
    warnings.push(`SECURITY: ${security2.length} data-module security filter(s) detected \u2014 NOT ported into the model spec. Run the skill's RLS flow (scripts/apply_sigma_rls.py) after posting the model; skipping leaves ALL rows visible to everyone.`);
  }
  return {
    model: { name: modelName || model.name, schemaVersion: 1, pages: [{ id: sigmaShortId(), name: "Page 1", elements }] },
    warnings,
    stats,
    ...security2.length ? { security: security2 } : {}
  };
}
function convertCognosToSigma(input, options = {}) {
  return convertCognosIR(normalizeCognosDataModule(input), options);
}
var AGG_MAP = {
  total: "Sum",
  sum: "Sum",
  average: "Avg",
  avg: "Avg",
  count: "Count",
  "count distinct": "CountDistinct",
  maximum: "Max",
  max: "Max",
  minimum: "Min",
  min: "Min"
};
var OVER_MAP = { total: "SumOver", sum: "SumOver", average: "AvgOver", count: "CountOver", maximum: "MaxOver", minimum: "MinOver" };
function aggFn(agg, inner) {
  const fn = AGG_MAP[agg] || "Sum";
  return `${fn}(${inner})`;
}
function translateCognosExpr(expr, qs, ensureRawCol, ctx) {
  const warnings = [];
  let f = (expr || "").trim();
  for (const bad of ["running-total", "running-count", "running-average", "running-difference", "moving-total", "moving-average", "rank", "percentile", "quantile", "tertile"]) {
    if (new RegExp(`\\b${bad}\\b`, "i").test(f)) warnings.push(`uses Cognos "${bad}" (window/running calc) \u2014 no clean single-column Sigma analog; needs manual authoring (window function).`);
  }
  f = f.replace(/\[[^\]]+\](?:\.\[[^\]]+\])*/g, (ref) => {
    const segs = ref.split(".").map((s) => s.replace(/[[\]]/g, "").trim());
    const item = segs[segs.length - 1];
    return `[${sigmaDisplayName(item)}]`;
  });
  f = translateCaseExpr(f);
  const identMap = /* @__PURE__ */ new Map();
  for (const it of qs.items || []) identMap.set(it.identifier.toLowerCase(), sigmaDisplayName(it.label || it.identifier));
  if (identMap.size) {
    const pfx = ctx && ctx.tableTail ? `${ctx.tableTail}/` : "";
    f = f.replace(/\[[^\]]*\]|[^[\]]+/g, (seg) => seg.startsWith("[") ? seg : seg.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*\()/g, (w) => {
      const d = identMap.get(w.toLowerCase());
      return d ? `[${pfx}${d}]` : w;
    }));
  }
  if (/\bcase\b[\s\S]*\bwhen\b/i.test(f)) warnings.push("a CASE expression could not be fully translated (nested or non-standard) \u2014 review/author manually.");
  f = f.replace(
    /\b(total|sum|average|count|maximum|minimum)\s*\(\s*([^()]*?)\s+for\s+([^()]*)\)/gi,
    (_m, fn, inner, scope) => {
      const over = OVER_MAP[lc(fn)] || "SumOver";
      const dims = scope.split(",").map((s) => s.trim()).join(", ");
      return `${over}(${inner.trim()}, ${dims})`;
    }
  );
  f = f.replace(/\b(total|sum|average|count|maximum|minimum)\s*\(/gi, (_m, fn) => `${AGG_MAP[lc(fn)] || "Sum"}(`);
  let guard = 0;
  while (/\bif\s*\(/i.test(f) && guard++ < 25) {
    f = f.replace(
      /\bif\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)\s*then\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)\s*else\s*/i,
      (_m, cond, thenv) => `If(${cond.trim()}, ${thenv.trim()}, `
    );
    if (!/\bif\s*\(/i.test(f)) break;
  }
  const opens = (f.match(/If\(/g) || []).length;
  const closes = (f.match(/\)/g) || []).length - (f.match(/\(/g) || []).length + opens;
  if (opens > 0 && closes < opens) f = f + ")".repeat(opens - Math.max(0, closes));
  f = f.replace(/_add_days\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, d, n) => `DateAdd("day", ${n.trim()}, ${d.trim()})`);
  f = f.replace(/_add_months\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, d, n) => `DateAdd("month", ${n.trim()}, ${d.trim()})`);
  f = f.replace(/_add_years\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, d, n) => `DateAdd("year", ${n.trim()}, ${d.trim()})`);
  f = f.replace(/_days_between\s*\(([^,]+),\s*([^)]+)\)/gi, (_m, a, b) => `DateDiff("day", ${b.trim()}, ${a.trim()})`);
  f = f.replace(/\bextract\s*\(\s*(year|month|day)\s*,\s*([^)]+)\)/gi, (_m, part, d) => `DatePart("${lc(part)}", ${d.trim()})`);
  f = f.replace(/\bsubstring\s*\(/gi, "Mid(").replace(/\bsubstr\s*\(/gi, "Mid(").replace(/\bupper\s*\(/gi, "Upper(").replace(/\blower\s*\(/gi, "Lower(").replace(/\btrim\s*\(/gi, "Trim(");
  f = f.replace(
    /\bsubstitute\s*\(\s*([^,]+?)\s*,\s*([^,]+?)\s*,\s*([^)]+?)\s*\)/gi,
    (_m, p, r, s) => `RegexpReplace(${s.trim()}, ${p.trim()}, ${r.trim()})`
  );
  const castRepl = (_m, x, ty) => /char|text|string|varchar/i.test(ty) ? `Text(${x.trim()})` : x.trim();
  f = f.replace(/\bcast\s*\(\s*([^,()]+?)\s+as\s+(\w+)[^)]*\)/gi, castRepl);
  f = f.replace(/\bcast\s*\(\s*([^,()]+?)\s*,\s*(\w+)[^)]*\)/gi, castRepl);
  f = f.replace(/\b(?:n?varchar|char)\s*\(\s*([^,)]+?)(?:\s*,\s*\d+)?\s*\)/gi, (_m, x) => `Text(${x.trim()})`);
  f = f.replace(/\b(?:decimal|double|float|number)\s*\(\s*([^,)]+?)(?:\s*,[^)]*)?\)/gi, (_m, x) => x.trim());
  f = f.replace(/\|\|/g, "&");
  f = f.replace(/\bcoalesce\s*\(/gi, "Coalesce(");
  f = f.replace(/\babs\s*\(/gi, "Abs(").replace(/\bround\s*\(/gi, "Round(").replace(/\bfloor\s*\(/gi, "Floor(").replace(/\bceiling\s*\(/gi, "Ceiling(").replace(/\bsqrt\s*\(/gi, "Sqrt(").replace(/\bln\s*\(/gi, "Ln(").replace(/\bmod\s*\(/gi, "Mod(").replace(/\bpower\s*\(/gi, "Power(");
  f = f.replace(/'([^']*)'/g, '"$1"');
  const known = /\b(If|Switch|Sum|Avg|Count|CountDistinct|Min|Max|SumOver|AvgOver|CountOver|MinOver|MaxOver|DateAdd|DateDiff|DatePart|Mid|Upper|Lower|Trim|Coalesce|Text|RegexpReplace|Replace|Abs|Round|Floor|Ceiling|Sqrt|Ln|Mod|Power)\b/;
  for (const m of f.matchAll(/\b([a-z][a-z0-9_-]*)\s*\(/gi)) {
    if (!known.test(m[1]) && !/^(and|or|not|in|like|between|then|else|end|case|when)$/i.test(m[1])) {
      warnings.push(`function "${m[1]}()" has no confirmed Sigma mapping \u2014 review/translate manually.`);
    }
  }
  return { formula: f, warnings };
}
function translateCaseExpr(s) {
  let guard = 0;
  while (/\bcase\b/i.test(s) && guard++ < 25) {
    const m = s.match(/\bcase\b([\s\S]*?)\bend\b/i);
    if (!m || m.index == null) break;
    const repl = convertCaseBody(m[1]);
    if (repl == null) break;
    s = s.slice(0, m.index) + repl + s.slice(m.index + m[0].length);
  }
  return s;
}
function convertCaseBody(body) {
  const em = body.match(/\belse\b([\s\S]*)$/i);
  const elseVal = em ? em[1].trim() : "Null";
  const head = em ? body.slice(0, em.index) : body;
  const fw = head.search(/\bwhen\b/i);
  if (fw < 0) return null;
  const selector = head.slice(0, fw).trim();
  const clauses = head.slice(fw).split(/\bwhen\b/i).map((c) => c.trim()).filter(Boolean);
  const pairs = [];
  for (const cl of clauses) {
    const tm = cl.match(/^([\s\S]*?)\bthen\b([\s\S]*)$/i);
    if (!tm) return null;
    pairs.push([tm[1].trim(), tm[2].trim()]);
  }
  if (!pairs.length) return null;
  if (selector) return `Switch(${[selector, ...pairs.flatMap((p) => [p[0], p[1]]), elseVal].join(", ")})`;
  let out = elseVal;
  for (let i = pairs.length - 1; i >= 0; i--) out = `If(${pairs[i][0]}, ${pairs[i][1]}, ${out})`;
  return out;
}
function parseJoinExpr(expr) {
  if (!expr) return null;
  const e = expr.replace(/[[\]]/g, "");
  const m = e.match(/([\w]+)\.([\w]+)\s*=\s*([\w]+)\.([\w]+)/);
  if (!m) return null;
  if (/\band\b|\bor\b/i.test(e)) return null;
  return { leftTable: m[1].trim(), leftCol: m[2].trim(), rightTable: m[3].trim(), rightCol: m[4].trim() };
}
var trunc = (s, n = 80) => s && s.length > n ? s.slice(0, n) + "\u2026" : s || "";

// converter/cognos-report.ts
var import_fast_xml_parser = __toESM(require_fxp(), 1);
var xmlParser = new import_fast_xml_parser.XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  trimValues: true,
  isArray: (n) => [
    "query",
    "dataItem",
    "list",
    "page",
    "detailFilter",
    "summaryFilter",
    "dataItemValue",
    "dataItemLabel",
    "listColumn",
    "reportPage",
    "crosstab",
    "crosstabNode",
    "crosstabNodeMember",
    "vizControl",
    "vcDataSet",
    "vcSlotData",
    "vcSlotDsColumn",
    "reportDataStore"
  ].includes(n)
});
var arr2 = (v) => Array.isArray(v) ? v : v == null ? [] : [v];
var txt = (v) => v == null ? "" : typeof v === "object" ? v["#text"] ?? "" : String(v);
function findAll(node, tag, out = []) {
  if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      if (k === tag) arr2(v).forEach((x) => out.push(x));
      arr2(v).forEach((x) => x && typeof x === "object" && findAll(x, tag, out));
    }
  }
  return out;
}
function convertCognosReportToSigma(xml2, options = {}) {
  resetIds();
  const warnings = [];
  const parsed = xmlParser.parse(xml2);
  const report = parsed.report || parsed;
  const reportName = txt(report.reportName) || options.workbookName || "Cognos Report";
  const queries = /* @__PURE__ */ new Map();
  for (const q of findAll(report.queries || report, "query")) {
    const name = q["@_name"] || "query";
    const items = /* @__PURE__ */ new Map();
    let subject = "";
    for (const di of findAll(q, "dataItem")) {
      const dn = di["@_name"];
      if (!dn) continue;
      const expr = txt(di.expression);
      const dataType = findAll(di, "XMLAttribute").find((x) => x["@_name"] === "RS_dataType")?.["@_value"];
      items.set(dn, { name: dn, expression: expr, aggregate: di["@_aggregate"], dataType });
      const m = expr.match(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[[^\]]+\]/);
      if (m && !subject) subject = m[1];
    }
    const filters = findAll(q, "detailFilter").map((f) => txt(f.filterExpression || f.expression)).filter(Boolean);
    queries.set(name, { name, subject, items, filters });
  }
  const prompts = /* @__PURE__ */ new Map();
  for (const sv of findAll(report, "selectValue")) {
    const p = sv["@_parameter"];
    if (!p) continue;
    const meta = prompts.get(p) || { options: [], valueRefs: {} };
    for (const o of findAll(sv, "selectOption")) {
      const v = o["@_useValue"];
      if (v && !meta.options.includes(v)) meta.options.push(v);
    }
    const d = txt(findAll(sv, "defaultSimpleSelection")[0]);
    if (d && meta.def == null) meta.def = d;
    prompts.set(p, meta);
  }
  for (const cc of findAll(report, "customControl")) {
    try {
      const cfg = JSON.parse(txt(cc.configuration));
      const p = cfg?.["Parameter"];
      if (p && cfg["Button label"] && cfg["Button value"]) {
        const meta = prompts.get(p) || { options: [], valueRefs: {} };
        meta.valueRefs[cfg["Button label"]] = String(cfg["Button value"]);
        if (!meta.options.includes(cfg["Button label"])) meta.options.push(cfg["Button label"]);
        prompts.set(p, meta);
      }
    } catch {
    }
  }
  const controls = /* @__PURE__ */ new Map();
  const registerPrompt = (p) => {
    if (controls.has(p)) return;
    const meta = prompts.get(p);
    const ctrl = {
      id: sigmaShortId(),
      kind: "control",
      controlId: p,
      name: sigmaDisplayName(p),
      controlType: "segmented",
      source: { kind: "manual", valueType: "text", values: [...meta?.options || []], labels: (meta?.options || []).map(() => null) },
      value: meta?.def ?? meta?.options?.[0] ?? null
    };
    if (!meta?.options?.length) {
      warnings.push(`prompt '${p}': no <selectValue> options found in the report \u2014 emitted an empty segmented control; add its values in Sigma.`);
    }
    controls.set(p, ctrl);
  };
  const translateModelRef = (ref) => ref.replace(/\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`).replace(/\[([^\]/]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
  const translate = (expr, q) => {
    const warns = [];
    let f = (expr || "").trim();
    if (f.startsWith("#") || /#\s*sql\s*\(|'token'/.test(f)) {
      const norm = (s) => s.replace(/[\s'"]+/g, "");
      const mA = f.match(/^#\s*prompt\(\s*'([^']+)'\s*,\s*'token'\s*(?:,\s*'([^']*)')?\s*\)\s*#$/s);
      if (mA) {
        const [, p, defRef] = mA;
        registerPrompt(p);
        const meta = prompts.get(p);
        const defaultFormula = defRef ? translateModelRef(defRef) : void 0;
        const defaultOption = defRef && meta ? Object.keys(meta.valueRefs).find((k) => norm(meta.valueRefs[k]) === norm(defRef)) : void 0;
        const branches = [];
        for (const opt2 of meta?.options || []) {
          if (opt2 === defaultOption) continue;
          let refFormula = meta.valueRefs[opt2] ? translateModelRef(meta.valueRefs[opt2]) : void 0;
          if (!refFormula) {
            const di = q.items.get(opt2) || [...q.items.values()].find((d) => d.name.toLowerCase() === opt2.toLowerCase());
            if (di && !di.expression.trim().startsWith("#")) refFormula = translateModelRef(di.expression.trim());
          }
          if (refFormula) branches.push(`"${opt2}", ${refFormula}`);
          else warns.push(`prompt '${p}' option "${opt2}" could not be mapped to a model column \u2014 left out of the Switch; add the branch manually.`);
        }
        if (defaultFormula && branches.length) {
          return { formula: `Switch([${p}], ${branches.join(", ")}, ${defaultFormula})`, warns };
        }
        if (defaultFormula) {
          warns.push(`prompt '${p}': no swap options resolved \u2014 emitted only the macro's default column.`);
          return { formula: defaultFormula, warns };
        }
      }
      const mB = f.match(/^#\s*'([^']*)'\s*\+\s*prompt\(\s*'([^']+)'\s*,\s*'token'\s*\)\s*\+\s*'([^']*)'\s*#$/s);
      if (mB) {
        const [, pre, p, suf] = mB;
        registerPrompt(p);
        const meta = prompts.get(p);
        if (meta?.options?.length) {
          const def = meta.def && meta.options.includes(meta.def) ? meta.def : meta.options[meta.options.length - 1];
          const branches = meta.options.filter((o) => o !== def).map((o) => `"${o}", ${translateModelRef(pre + o + suf)}`);
          const defaultFormula = translateModelRef(pre + def + suf);
          return { formula: branches.length ? `Switch([${p}], ${branches.join(", ")}, ${defaultFormula})` : defaultFormula, warns };
        }
        warns.push(`dataItem builds a column ref from prompt '${p}' but the report carries no option list for it \u2014 emitted a placeholder.`);
        return { formula: `/* MACRO \u2014 manual: ${f.slice(0, 60)} */`, warns };
      }
      const promptName = (f.match(/prompt\(\s*'([^']+)'/) || [])[1];
      if (promptName) registerPrompt(promptName);
      warns.push(`dataItem uses a Cognos macro (#\u2026#${promptName ? `, prompt '${promptName}'` : ""}) that builds the column/SQL at runtime \u2014 model it in Sigma as a control + Switch([Control], \u2026). Emitted a placeholder.`);
      return { formula: promptName ? `Switch([${promptName}] /* map prompt tokens to columns */)` : `/* MACRO \u2014 manual: ${f.slice(0, 60)} */`, warns };
    }
    f = f.replace(
      /\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]\.\[([^\]]+)\]/g,
      (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`
    );
    f = f.replace(/\[([^\]]+)\]\.\[([^\]]+)\]/g, (_m, subj, col) => `[${sigmaDisplayName(subj)}/${sigmaDisplayName(col)}]`);
    f = f.replace(/\[([^\]\/]+)\]/g, (whole, nm) => q.items.has(nm) ? `[${sigmaDisplayName(nm)}]` : whole);
    f = f.replace(/prompt\(\s*'([^']+)'[^)]*\)/g, (_m, p) => {
      registerPrompt(p);
      return `[${p}]`;
    });
    const dsl = translateCognosExpr(
      f,
      { identifier: q.subject || "Q", items: [] },
      () => "",
      {}
    );
    dsl.warnings.forEach((w) => warns.push(w));
    return { formula: dsl.formula, warns };
  };
  const formatFromNode = (node) => {
    const cf = findAll(node, "currencyFormat")[0];
    const pf = findAll(node, "percentFormat")[0];
    const nf = findAll(node, "numberFormat")[0];
    const dec = (x, d) => x?.["@_decimalSize"] != null ? Number(x["@_decimalSize"]) : d;
    const scaled = (x) => x?.["@_scale"] != null || /[KMB]/.test(String(x?.["@_pattern"] || ""));
    if (cf) return { kind: "number", formatString: scaled(cf) ? `$,.${dec(cf, 1) + 2}s` : `$,.${dec(cf, 2)}f` };
    if (pf) return { kind: "number", formatString: `,.${dec(pf, 0)}%` };
    if (nf) return { kind: "number", formatString: scaled(nf) ? `$,.${dec(nf, 1) + 2}s` : `,.${dec(nf, 2)}f` };
    return void 0;
  };
  const pages = [];
  const reportPages = findAll(report.layouts || report, "reportPage").concat(findAll(report.layouts || report, "page"));
  const lists = findAll(report, "list");
  const pageEls = [];
  const dmSource = (q) => ({ kind: "data-model", dataModelId: options.dataModelId || "<DM_ID \u2014 wire after posting the data model>", elementId: q.subject ? sigmaDisplayName(q.subject) : "<element>" });
  const ensureFilterCol = (el, q, itemName) => {
    const di = q.items.get(itemName);
    if (!di) return void 0;
    const want = sigmaDisplayName(di.name);
    const existing = (el.columns || []).find((c) => c.name === want);
    if (existing) return existing.id;
    const { formula, warns } = translate(di.expression, q);
    warns.forEach((w) => warnings.push(`"${q.name}.${itemName}": ${w}`));
    const id = sigmaShortId();
    (el.columns ||= []).push({ id, name: want, formula, hidden: true });
    return id;
  };
  const applyQueryFilters = (el, q) => {
    for (const fx of q.filters) {
      const m = fx.match(/^\s*\[([^\]]+)\]\s+(in)\s*\(([^)]*)\)\s*$/i) || fx.match(/^\s*\[([^\]]+)\]\s*(=)\s*(.+?)\s*$/);
      const fail = (why) => warnings.push(`filter "${fx.slice(0, 80)}" on query "${q.name}": ${why} \u2014 re-create as a Sigma element/page filter.`);
      if (!m) {
        fail("not a simple =/in filter");
        continue;
      }
      const [, nm, op, rhs] = m;
      if (!q.items.has(nm)) {
        fail(`[${nm}] is not a dataItem in the query`);
        continue;
      }
      const colId = ensureFilterCol(el, q, nm);
      if (!colId) {
        fail("filter column could not be added");
        continue;
      }
      const col = el.columns.find((c) => c.id === colId);
      const textCol = /^Text\(/.test(col.formula);
      const lit = (s) => {
        const t = s.trim().replace(/^['"](.*)['"]$/, "$1");
        return t !== "" && /^-?[\d.]+$/.test(t) && !Number.isNaN(Number(t)) && !textCol ? Number(t) : t;
      };
      const prompt = rhs.trim().match(/^\?(\w+)\?$/);
      if (prompt && op === "=") {
        const p = prompt[1];
        registerPrompt(p);
        const boolId = sigmaShortId();
        el.columns.push({ id: boolId, name: `${col.name} = ${p}`, formula: `[${col.name}] = [${p}]`, hidden: true });
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: boolId, kind: "list", mode: "include", values: [true] });
      } else if (op.toLowerCase() === "in") {
        const values = rhs.split(",").map((s) => lit(s)).filter((v) => v !== "");
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: colId, kind: "list", mode: "include", values });
      } else if (rhs.trim().startsWith("?")) {
        fail("unsupported prompt comparison");
      } else {
        (el.filters ||= []).push({ id: sigmaShortId(), columnId: colId, kind: "list", mode: "include", values: [lit(rhs)] });
      }
    }
  };
  for (const sg of findAll(report, "singleton")) {
    const qName = sg["@_refQuery"];
    const q = queries.get(qName);
    if (!q) {
      warnings.push(`<singleton> "${sg["@_name"]}" refQuery="${qName}" has no matching query \u2014 skipped.`);
      continue;
    }
    const ref = findAll(sg, "dataItemValue").map((d) => d["@_refDataItem"]).find(Boolean);
    const di = ref ? q.items.get(ref) : void 0;
    if (!di) {
      warnings.push(`<singleton> "${sg["@_name"]}" has no resolvable dataItem ("${ref}") \u2014 skipped.`);
      continue;
    }
    const cols = [];
    const idByName = /* @__PURE__ */ new Map();
    const addKpiCol = (nm) => {
      if (idByName.has(nm)) return idByName.get(nm);
      const d = q.items.get(nm);
      if (!d) return void 0;
      for (const sm of d.expression.matchAll(/\[([^\]/.]+)\]/g)) {
        if (sm[1] !== nm && q.items.has(sm[1])) addKpiCol(sm[1]);
      }
      const { formula, warns } = translate(d.expression, q);
      warns.forEach((w) => warnings.push(`"${qName}.${nm}": ${w}`));
      const referencesSibling = [...q.items.keys()].some((k) => k !== nm && formula.toLowerCase().includes(`[${sigmaDisplayName(k).toLowerCase()}]`));
      const hasAgg = /\b(Sum|Avg|Min|Max|Count|CountDistinct|Median)\s*\(/.test(formula);
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(nm), formula: referencesSibling || hasAgg ? formula : `Sum(${formula})` });
      idByName.set(nm, id);
      return id;
    };
    const valId = addKpiCol(ref);
    const fmt = formatFromNode(sg);
    if (fmt) cols.find((c) => c.id === valId).format = fmt;
    if (findAll(sg, "conditionalStyleRef").length) {
      warnings.push(`singleton "${sg["@_name"]}" (${ref}) uses conditional styling (e.g. up/down KPI icons) \u2014 not portable to a Sigma kpi-chart spec; the VALUE is preserved, re-create the icon rule manually.`);
    }
    const el = {
      id: sigmaShortId(),
      kind: "kpi-chart",
      name: di.name,
      source: dmSource(q),
      columns: cols,
      order: cols.map((c) => c.id),
      value: { columnId: valId }
    };
    applyQueryFilters(el, q);
    pageEls.push(el);
  }
  for (const L of lists) {
    const qName = L["@_refQuery"];
    const q = queries.get(qName);
    if (!q) {
      warnings.push(`<list> refQuery="${qName}" has no matching query \u2014 skipped.`);
      continue;
    }
    const colRefs = findAll(L, "dataItemValue").map((d) => d["@_refDataItem"]).filter(Boolean);
    const refs = colRefs.length ? colRefs : [...q.items.keys()];
    const columns = [];
    const AGG = { total: "Sum", summary: "Sum", aggregate: "Sum", calculated: "Sum", average: "Avg", count: "Count", maximum: "Max", minimum: "Min" };
    const isMeasureItem = (d) => !!d.aggregate && d.aggregate !== "none";
    const grouped = refs.some((r) => {
      const d = q.items.get(r);
      return d && isMeasureItem(d);
    }) && refs.some((r) => {
      const d = q.items.get(r);
      return d && !isMeasureItem(d);
    });
    const dimIds = [];
    const measureIds = [];
    const footerRefs = [];
    for (const r of refs) {
      const di = q.items.get(r);
      if (!di) {
        const m = r.match(/^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\((.+?)\)\d*$/i);
        if (m && q.items.get(m[2])) {
          if (grouped) {
            footerRefs.push(r);
            continue;
          }
          columns.push({ id: sigmaShortId(), name: sigmaDisplayName(r), formula: `${AGG[m[1].toLowerCase()]}([${sigmaDisplayName(m[2])}])` });
          continue;
        }
        warnings.push(`list column "${r}" not found in query "${qName}" \u2014 skipped.`);
        continue;
      }
      const { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${qName}.${r}": ${w}`));
      const id = sigmaShortId();
      if (grouped && isMeasureItem(di)) {
        const _aggk = di.aggregate.toLowerCase();
        if (!AGG[_aggk]) warnings.push(`list measure "${di.name}" (query "${qName}"): unmapped Cognos aggregate '${di.aggregate}' \u2014 defaulted to Sum (degraded); verify parity or add the mapping (refs/cognos-coverage.md).`);
        const fn = AGG[_aggk] || "Sum";
        columns.push({ id, name: sigmaDisplayName(di.name), formula: /^\s*(Sum|Avg|Min|Max|Count|CountDistinct)\s*\(/.test(formula) ? formula : `${fn}(${formula})` });
        measureIds.push(id);
      } else {
        columns.push({ id, name: sigmaDisplayName(di.name), formula });
        if (grouped) dimIds.push(id);
      }
    }
    if (footerRefs.length) {
      warnings.push(`list "${qName}": footer total(s) ${footerRefs.join(", ")} \u2014 the grouped Sigma table already aggregates per group; add a grand-total via the table's totals UI (a duplicate Sum column would double-aggregate).`);
    }
    for (const si of findAll(L, "sortItem")) {
      if (si["@_refDataItem"]) warnings.push(`list "${qName}" sorts by "${si["@_refDataItem"]}" (${si["@_sortOrder"] || "ascending"}) \u2014 table sort isn't part of the Sigma workbook spec; apply the sort in the UI.`);
    }
    const condRefs = [...new Set(findAll(L, "conditionalStyleRef").map((c) => c["@_refConditionalStyle"]).filter(Boolean))];
    if (condRefs.length) warnings.push(`list "${qName}" uses conditional style(s) ${condRefs.map((r) => `"${r}"`).join(", ")} \u2014 threshold-driven formats/styles aren't portable to the Sigma spec; set a column format (e.g. $,.3s) or conditional formatting in the UI.`);
    const el = {
      id: sigmaShortId(),
      kind: "table",
      name: `${q.subject ? sigmaDisplayName(q.subject) + " \u2014 " : ""}${qName}`,
      source: dmSource(q),
      columns,
      order: columns.map((c) => c.id)
    };
    if (grouped && dimIds.length && measureIds.length) {
      el.groupings = [{ id: sigmaShortId(), groupBy: dimIds, calculations: measureIds }];
    }
    applyQueryFilters(el, q);
    pageEls.push(el);
  }
  const isTotal = (r) => /^(Total|Summary|Aggregate|Average|Count|Maximum|Minimum)\(/i.test(r || "");
  for (const X of findAll(report, "crosstab")) {
    const qName = X["@_refQuery"];
    const q = queries.get(qName);
    if (!q) {
      warnings.push(`<crosstab> refQuery="${qName}" has no matching query \u2014 skipped.`);
      continue;
    }
    const edge = (subtree) => [...new Set(findAll(subtree || {}, "crosstabNodeMember").map((m) => m["@_refDataItem"]).filter((r) => r && !isTotal(r)))];
    const rowRefs = edge(X.crosstabRows);
    const colRefs = edge(X.crosstabColumns);
    let measRefs = [...new Set(findAll(X.crosstabCorner || {}, "dataItemLabel").map((d) => d["@_refDataItem"]).filter((r) => r && !isTotal(r)))];
    if (!measRefs.length) measRefs = [...q.items.keys()].filter((k) => !rowRefs.includes(k) && !colRefs.includes(k) && !isTotal(k));
    const cols = [];
    const mk = (ref, agg) => {
      const di = q.items.get(ref);
      if (!di) {
        warnings.push(`crosstab "${qName}" member "${ref}" not in query \u2014 skipped.`);
        return null;
      }
      const { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${qName}.${ref}": ${w}`));
      const id = sigmaShortId();
      cols.push({ id, name: sigmaDisplayName(di.name), formula: agg ? `Sum(${formula})` : formula });
      return { id };
    };
    const rowsBy = rowRefs.map((r) => mk(r, false)).filter(Boolean);
    const columnsBy = colRefs.map((c) => mk(c, false)).filter(Boolean);
    const values = measRefs.map((m) => mk(m, true)).filter(Boolean).map((o) => o.id);
    if (!values.length || !rowsBy.length && !columnsBy.length) warnings.push(`crosstab "${qName}" missing a measure or both edges \u2014 review the pivot.`);
    const el = {
      id: sigmaShortId(),
      kind: "pivot-table",
      name: `${q.subject ? sigmaDisplayName(q.subject) + " \u2014 " : ""}${qName} (crosstab)`,
      source: dmSource(q),
      columns: cols,
      order: cols.map((c) => c.id),
      rowsBy,
      columnsBy,
      values
    };
    applyQueryFilters(el, q);
    pageEls.push(el);
  }
  const dsToQuery = /* @__PURE__ */ new Map();
  for (const ds of findAll(report, "reportDataStore")) {
    const nm = ds["@_name"];
    const rq = findAll(ds, "dsV5ListQuery").map((x) => x["@_refQuery"]).find(Boolean);
    if (nm && rq) dsToQuery.set(nm, rq);
  }
  const ROLLUP_AGG = { total: "Sum", sum: "Sum", average: "Avg", avg: "Avg", count: "Count", countdistinct: "CountDistinct", maximum: "Max", minimum: "Min" };
  const VIZ_KIND = {
    "com.ibm.vis.clusteredbar": "bar-chart",
    "com.ibm.vis.stackedbar": "bar-chart",
    "com.ibm.vis.clusteredcolumn": "bar-chart",
    "com.ibm.vis.stackedcolumn": "bar-chart",
    "com.ibm.vis.line": "line-chart",
    "com.ibm.vis.spline": "line-chart",
    "com.ibm.vis.area": "area-chart",
    "com.ibm.vis.stackedarea": "area-chart",
    "com.ibm.vis.pie": "pie-chart",
    "com.ibm.vis.donut": "donut-chart",
    "com.ibm.vis.clusteredcombination": "combo-chart",
    "com.ibm.vis.stackedcombination": "combo-chart",
    "com.ibm.vis.bubble": "scatter-chart",
    "com.ibm.vis.scatter": "scatter-chart"
  };
  const VIZ_NOANALOG = {
    "com.ibm.vis.network": "network diagram",
    "com.ibm.vis.wordcloud": "word cloud",
    "com.ibm.vis.packedbubble": "packed bubble",
    "com.ibm.vis.treemap": "treemap"
  };
  const isMapViz = (t) => /tiledmap|choropleth|\bmap\b/.test(t);
  const chartSource = dmSource;
  const COGNOS_SCHEME = {
    // sequential (single-hue ramps)
    blue: ["#deebf7", "#9ecae1", "#3182bd"],
    blues: ["#deebf7", "#9ecae1", "#3182bd"],
    green: ["#e5f5e0", "#a1d99b", "#31a354"],
    greens: ["#e5f5e0", "#a1d99b", "#31a354"],
    orange: ["#fee6ce", "#fdae6b", "#e6550d"],
    oranges: ["#fee6ce", "#fdae6b", "#e6550d"],
    red: ["#fee0d2", "#fc9272", "#de2d26"],
    reds: ["#fee0d2", "#fc9272", "#de2d26"],
    purple: ["#efedf5", "#bcbddc", "#756bb1"],
    heat: ["#ffffcc", "#fd8d3c", "#bd0026"],
    sequential: ["#ffffcc", "#fd8d3c", "#bd0026"],
    // diverging
    diverging: ["#a50026", "#f46d43", "#fee090", "#74add1", "#313695"],
    redblue: ["#a50026", "#f46d43", "#fee090", "#74add1", "#313695"],
    redgreen: ["#d73027", "#fee08b", "#1a9850"]
  };
  const SEQ_DEFAULT = COGNOS_SCHEME.sequential;
  const schemeFromSignal = (sig) => {
    const key = String(sig || "").toLowerCase().replace(/[^a-z]/g, "");
    for (const k of Object.keys(COGNOS_SCHEME)) if (key.includes(k)) return [...COGNOS_SCHEME[k]];
    return [...SEQ_DEFAULT];
  };
  const vizColorSignal = (V) => {
    for (const pv of findAll(V, "vizPropertyValues")) {
      for (const [, v] of Object.entries(pv)) {
        for (const p of arr2(v)) {
          const nm = String(p?.["@_name"] || "");
          if (/palette|colou?r.?scheme|colou?rmodel/i.test(nm)) {
            const val = txt(p);
            if (val) return val;
          }
        }
      }
    }
    const pal = findAll(V, "vcSlotData").map((s) => s["@_refPaletteDefinition"] || s["@_refPalette"]).find(Boolean) || V["@_refPaletteDefinition"] || V["@_refPalette"];
    return pal ? String(pal) : void 0;
  };
  const buildRefMarks = (V, q, vizName) => {
    const nodes = [...findAll(V, "baseline"), ...findAll(V, "vizBaseline")];
    const out = [];
    for (const b of nodes) {
      if (String(b["@_visible"] ?? b["@_show"] ?? "true").toLowerCase() === "false") continue;
      const onX = /^(category|categories|x|item|itemaxis)$/i.test(String(b["@_refAxis"] || b["@_axis"] || ""));
      const axis = onX ? "axis" : "series";
      let formula = "";
      const di = b["@_refDataItem"] ? q.items.get(b["@_refDataItem"]) : void 0;
      if (di) {
        const { formula: f, warns } = translate(di.expression, q);
        warns.forEach((w) => warnings.push(`"${vizName}.baseline ${b["@_refDataItem"]}": ${w}`));
        formula = /^\s*(Sum|Avg|Min|Max|Count|CountDistinct|Median)\s*\(/.test(f) ? f : `Avg(${f})`;
      } else {
        const v = b["@_value"] ?? b["@_position"] ?? txt(b.value) ?? txt(b);
        if (v != null && String(v).trim() !== "" && /^-?[\d.]+$/.test(String(v).trim())) formula = String(v).trim();
      }
      if (!formula) {
        warnings.push(`chart "${vizName}": a reference line / baseline had no static value or data-item measure \u2014 skipped (re-add it in the workbook).`);
        continue;
      }
      const rm = {
        type: "line",
        axis,
        value: { type: "formula", formula },
        line: { color: String(b["@_color"] || b["@_lineColor"] || "#ef4444"), width: 2 }
      };
      const label = b["@_label"] || b["@_text"] || (di ? sigmaDisplayName(di.name) : void 0);
      if (label) rm.label = { visibility: "shown", text: String(label) };
      out.push(rm);
    }
    return out;
  };
  for (const V of findAll(report, "vizControl")) {
    const vizType = String(V["@_type"] || "").toLowerCase();
    const vizName = V["@_name"] || "Chart";
    const dsName = findAll(V, "vcDataSet").map((d) => d["@_refDataStore"]).find(Boolean);
    const qName = dsName ? dsToQuery.get(dsName) : void 0;
    const q = qName ? queries.get(qName) : void 0;
    if (!q) {
      warnings.push(`<vizControl> "${vizName}" (${vizType}): no resolvable query (dataStore "${dsName}") \u2014 chart skipped.`);
      continue;
    }
    const slot = (id) => {
      const out = [];
      for (const sd of findAll(V, "vcSlotData")) {
        if (String(sd["@_idSlot"] || "").toLowerCase() !== id) continue;
        for (const c of findAll(sd, "vcSlotDsColumn")) if (c["@_refDsColumn"]) {
          out.push({ ref: c["@_refDsColumn"], rollup: c["@_rollupMethod"], sort: c["@_dsSort"], format: formatFromNode(c) });
        }
      }
      return out;
    };
    const cols = [];
    const seen = /* @__PURE__ */ new Map();
    const addCol = (e, measure, categorical = false) => {
      if (!e) return void 0;
      const di = q.items.get(e.ref);
      if (!di) {
        warnings.push(`chart "${vizName}" column "${e.ref}" not in query "${qName}" \u2014 skipped.`);
        return void 0;
      }
      const nm = sigmaDisplayName(di.name);
      if (seen.has(nm)) return seen.get(nm);
      let { formula, warns } = translate(di.expression, q);
      warns.forEach((w) => warnings.push(`"${vizName}.${e.ref}": ${w}`));
      if (categorical && !measure && (di.dataType === "1" || di.dataType === "2")) formula = `Text(${formula})`;
      const id = sigmaShortId();
      let fn = "";
      if (measure) {
        const _rk = String(e.rollup || "").toLowerCase();
        if (_rk && !ROLLUP_AGG[_rk]) warnings.push(`chart "${vizName}" measure "${nm}": unmapped Cognos rollup '${e.rollup}' \u2014 defaulted to Sum (degraded); verify parity (refs/cognos-coverage.md).`);
        fn = ROLLUP_AGG[_rk] || "Sum";
      }
      const col = { id, name: nm, formula: measure ? `${fn}(${formula})` : formula };
      if (e.format) col.format = e.format;
      cols.push(col);
      seen.set(nm, id);
      return id;
    };
    const cats = slot("categories"), series = slot("series"), vals = slot("values");
    const sizes = slot("size"), xs = slot("x"), ys = slot("y"), colorSlot = slot("color");
    const kind = VIZ_KIND[vizType];
    if (isMapViz(vizType)) {
      const lat = slot("latlonglocations.latitude")[0] || slot("latitude")[0];
      const lon = slot("latlonglocations.longitude")[0] || slot("longitude")[0];
      const region = slot("locations")[0] || slot("location")[0];
      if (lat && lon) {
        const latId = addCol(lat, false), lonId = addCol(lon, false);
        const sizeId = addCol(slot("latlongsize")[0] || sizes[0], true);
        const colorId = addCol(slot("latlongcolor")[0] || colorSlot[0], true);
        const el2 = { id: sigmaShortId(), kind: "point-map", name: vizName, source: chartSource(q), columns: cols, order: [] };
        if (latId) el2.latitude = { id: latId };
        if (lonId) el2.longitude = { id: lonId };
        if (sizeId) el2.size = { id: sizeId };
        if (colorId) el2.color = { by: "scale", column: colorId };
        el2.order = cols.map((c) => c.id);
        if (!cols.length) {
          warnings.push(`<vizControl> map "${vizName}" had no resolvable lat/long columns \u2014 skipped.`);
          continue;
        }
        applyQueryFilters(el2, q);
        pageEls.push(el2);
      } else if (region) {
        const regId = addCol(region, false);
        const colorId = addCol(slot("locationcolor")[0] || colorSlot[0] || slot("locationheight")[0], true);
        if (!regId) {
          warnings.push(`<vizControl> map "${vizName}" had no resolvable location column \u2014 skipped.`);
          continue;
        }
        const el2 = { id: sigmaShortId(), kind: "region-map", name: vizName, source: chartSource(q), columns: cols, order: cols.map((c) => c.id), region: { id: regId, regionType: "country" } };
        if (colorId) el2.color = { by: "scale", column: colorId };
        warnings.push(`chart "${vizName}" \u2192 region-map: defaulted regionType to "country" \u2014 set it to match your data (country / us-state / us-county / us-zipcode / us-cbsa / us-postal-place / ca-province).`);
        applyQueryFilters(el2, q);
        pageEls.push(el2);
      } else {
        for (const c of findAll(V, "vcSlotDsColumn")) if (c["@_refDsColumn"]) addCol({ ref: c["@_refDsColumn"], rollup: c["@_rollupMethod"] }, !!c["@_rollupMethod"]);
        if (!cols.length) {
          warnings.push(`<vizControl> map "${vizName}" (${vizType}) had no resolvable columns \u2014 skipped.`);
          continue;
        }
        warnings.push(`chart "${vizName}" is a Cognos map (${vizType}) with no lat/long or named-location slot \u2014 emitted its data as a table; add geographic columns + a map in the workbook.`);
        const fb = { id: sigmaShortId(), kind: "table", name: `${vizName} (was map)`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) };
        applyQueryFilters(fb, q);
        pageEls.push(fb);
      }
      continue;
    }
    if (!kind) {
      const label = VIZ_NOANALOG[vizType] || vizType.replace("com.ibm.vis.", "");
      for (const c of findAll(V, "vcSlotDsColumn")) if (c["@_refDsColumn"]) addCol({ ref: c["@_refDsColumn"], rollup: c["@_rollupMethod"] }, !!c["@_rollupMethod"]);
      if (!cols.length) {
        warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable columns \u2014 skipped.`);
        continue;
      }
      warnings.push(`chart "${vizName}" is a Cognos ${label} (${vizType}) \u2014 Sigma has no native equivalent; emitted its data as a table. Re-pick a Sigma chart in the workbook.`);
      const fb = { id: sigmaShortId(), kind: "table", name: `${vizName} (was ${label})`, source: chartSource(q), columns: cols, order: cols.map((c) => c.id) };
      applyQueryFilters(fb, q);
      pageEls.push(fb);
      continue;
    }
    const el = { id: sigmaShortId(), kind, name: vizName, source: chartSource(q), columns: [], order: [] };
    if (kind === "pie-chart" || kind === "donut-chart") {
      const colorId = addCol(cats[0] || colorSlot[0], false);
      const valId = addCol(vals[0] || sizes[0], true);
      if (colorId) el.color = { id: colorId };
      if (valId) el.value = { id: valId };
    } else if (kind === "scatter-chart") {
      const dimSlot = series[0] || colorSlot[0];
      const xId = addCol(xs[0] || cats[0], true);
      const yId = addCol(ys[0] || vals[0] || sizes[0], true);
      const dId = dimSlot ? addCol(dimSlot, false) : void 0;
      const szId = sizes[0] && sizes[0] !== (ys[0] || vals[0]) ? addCol(sizes[0], true) : void 0;
      if (xId && yId && dId) {
        const grpId = sigmaShortId();
        const srcName = `${vizName} (scatter source)`;
        const src = {
          id: sigmaShortId(),
          kind: "table",
          name: srcName,
          source: chartSource(q),
          columns: cols,
          order: cols.map((c) => c.id),
          groupings: [{ id: grpId, groupBy: [dId], calculations: szId ? [xId, yId, szId] : [xId, yId] }],
          visibleAsSource: false
        };
        applyQueryFilters(src, q);
        const byId = new Map(cols.map((c) => [c.id, c]));
        const raw = (srcColId) => {
          const sc = byId.get(srcColId);
          return { id: sigmaShortId(), name: sc.name, formula: `[${srcName}/${sc.name}]` };
        };
        const sDim = raw(dId), sX = raw(xId), sY = raw(yId);
        const scols = [sDim, sX, sY];
        el.source = { kind: "table", elementId: src.id, groupingId: grpId };
        el.xAxis = { columnId: sX.id };
        el.yAxis = { columnIds: [sY.id] };
        el.color = { by: "category", column: sDim.id };
        if (szId) {
          const sSz = raw(szId);
          scols.push(sSz);
          el.size = { id: sSz.id };
        }
        el.columns = scols;
        el.order = scols.map((c) => c.id);
        const sRefMarks2 = buildRefMarks(V, q, vizName);
        if (sRefMarks2.length) el.refMarks = sRefMarks2;
        pageEls.push(src);
        pageEls.push(el);
        continue;
      }
      if (xId) el.xAxis = { columnId: xId };
      if (yId) el.yAxis = { columnIds: [yId] };
      if (dId) el.color = { by: "category", column: dId };
      const sRefMarks = buildRefMarks(V, q, vizName);
      if (sRefMarks.length) el.refMarks = sRefMarks;
    } else {
      const xId = addCol(cats[0], false, true);
      if (xId) {
        el.xAxis = { columnId: xId };
        if (cats[0]?.sort) el.xAxis.sort = { by: xId, direction: /desc/i.test(cats[0].sort) ? "descending" : "ascending" };
      }
      if (cats.length > 1) {
        warnings.push(`chart "${vizName}": Cognos used ${cats.length} category levels; Sigma x-axis takes one \u2014 bound the first, kept the rest as columns.`);
        cats.slice(1).forEach((c) => addCol(c, false, true));
      }
      const yIds = [...vals, ...sizes].map((v) => addCol(v, true)).filter(Boolean);
      if (yIds.length) el.yAxis = { columnIds: yIds };
      else warnings.push(`chart "${vizName}" (${kind}) resolved no measure for the value axis \u2014 add a measure in the workbook.`);
      const colorE = colorSlot[0];
      const colorIsMeasure = !series[0] && !!colorE && !!colorE.rollup && !!q.items.get(colorE.ref);
      if (colorIsMeasure) {
        const baseId = addCol(colorE, true);
        const base = cols.find((c) => c.id === baseId);
        if (base) {
          const dupId = sigmaShortId();
          const dup = { id: dupId, name: `${base.name} (color)`, formula: base.formula };
          if (base.format) dup.format = base.format;
          cols.push(dup);
          el.color = { by: "scale", column: dupId, scheme: schemeFromSignal(vizColorSignal(V)) };
        }
      } else {
        const cId = addCol(series[0] || colorE, false);
        if (cId) el.color = { by: "category", column: cId };
      }
      const refMarks = buildRefMarks(V, q, vizName);
      if (refMarks.length) el.refMarks = refMarks;
      if (kind === "bar-chart") {
        el.stacking = /stacked/.test(vizType) ? "stacked" : "none";
        if (/\bbar\b/.test(vizType) && !/column/.test(vizType)) el.orientation = "horizontal";
      }
      if (kind === "combo-chart" && yIds.length > 1) warnings.push(`chart "${vizName}" \u2192 combo-chart: all measures placed on the primary axis as the same mark \u2014 set per-series shape / secondary axis in the workbook.`);
    }
    el.columns = cols;
    el.order = cols.map((c) => c.id);
    if (!cols.length) {
      warnings.push(`<vizControl> "${vizName}" (${vizType}) had no resolvable slot columns \u2014 skipped.`);
      continue;
    }
    applyQueryFilters(el, q);
    pageEls.push(el);
  }
  const controlEls = [...controls.values()];
  pages.push({ id: sigmaShortId(), name: reportPages[0]?.["@_name"] || "Report", elements: [...controlEls, ...pageEls] });
  for (const fnode of findAll(report, "summaryFilter")) {
    const fexpr = txt(fnode.filterExpression || fnode.expression);
    if (fexpr) warnings.push(`summary filter: "${fexpr.slice(0, 80)}" \u2014 post-aggregation filter; re-create as a Sigma filter on the aggregated column.`);
  }
  const stats = {
    queries: queries.size,
    tables: pageEls.filter((e) => e.kind === "table").length,
    pivots: pageEls.filter((e) => e.kind === "pivot-table").length,
    kpis: pageEls.filter((e) => e.kind === "kpi-chart").length,
    charts: pageEls.filter((e) => e.kind.endsWith("-chart") && e.kind !== "kpi-chart").length,
    maps: pageEls.filter((e) => e.kind.endsWith("-map")).length,
    columns: pageEls.reduce((n, e) => n + (e.columns?.length || 0), 0),
    filters: pageEls.reduce((n, e) => n + (e.filters?.length || 0), 0),
    controls: controls.size,
    refMarks: pageEls.reduce((n, e) => n + (e.refMarks?.length || 0), 0),
    scaleColors: pageEls.filter((e) => e.color?.by === "scale").length
  };
  return {
    workbook: { name: reportName, schemaVersion: 1, pages, controls: controlEls },
    warnings,
    stats
  };
}

// converter/cli.ts
function loadLearnedRules() {
  try {
    const p = join(homedir(), ".cognos-to-sigma", "learned-rules.json");
    const rules = JSON.parse(readFileSync(p, "utf8"));
    const arr3 = Array.isArray(rules) ? rules : rules.rules || [];
    if (arr3.length) console.error(`[learned-rules] applying ${arr3.length} customer rule(s) from ${p}`);
    return arr3;
  } catch {
    return [];
  }
}
var args = process.argv.slice(2);
var file = args.find((a) => !a.startsWith("--"));
var opt = (k, d = "") => {
  const i = args.indexOf("--" + k);
  return i >= 0 ? args[i + 1] : d;
};
if (!file) {
  console.error("usage: cli.ts <module.json|report.xml> [--connection X --database DB --schema S --dm ID]");
  process.exit(1);
}
var xml = readFileSync(file, "utf8");
var isReport = file.endsWith(".xml") || xml.trimStart().startsWith("<");
var res = isReport ? convertCognosReportToSigma(xml, { dataModelId: opt("dm", "<DM_ID>") }) : convertCognosToSigma(xml, { connectionId: opt("connection", "<CONNECTION_ID>"), database: opt("database"), schema: opt("schema"), learnedRules: loadLearnedRules() });
var payload = isReport ? res.workbook : res.model;
process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
console.error(`
[${isReport ? "report\u2192workbook" : "module\u2192data-model"}] stats: ${JSON.stringify(res.stats)}`);
var security = res.security;
if (security?.length) {
  const out = opt("security-out", "security.json");
  writeFileSync(out, JSON.stringify(security, null, 2));
  console.error(`SECURITY: ${security.length} rule(s) detected \u2192 ${out} \u2014 run scripts/apply_sigma_rls.py after posting the model (see SKILL.md "Security").`);
}
if (res.warnings.length) {
  console.error(`warnings (${res.warnings.length}) \u2014 translated where possible, flagged where not:`);
  res.warnings.forEach((w) => console.error("  ! " + w));
}
