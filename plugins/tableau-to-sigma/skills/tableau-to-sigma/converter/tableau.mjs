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

// node_modules/fast-xml-parser/src/util.js
var require_util = __commonJS({
  "node_modules/fast-xml-parser/src/util.js"(exports) {
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

// node_modules/fast-xml-parser/src/validator.js
var require_validator = __commonJS({
  "node_modules/fast-xml-parser/src/validator.js"(exports) {
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

// node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js
var require_OptionsBuilder = __commonJS({
  "node_modules/fast-xml-parser/src/xmlparser/OptionsBuilder.js"(exports) {
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

// node_modules/fast-xml-parser/src/xmlparser/xmlNode.js
var require_xmlNode = __commonJS({
  "node_modules/fast-xml-parser/src/xmlparser/xmlNode.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js
var require_DocTypeReader = __commonJS({
  "node_modules/fast-xml-parser/src/xmlparser/DocTypeReader.js"(exports, module) {
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

// node_modules/strnum/strnum.js
var require_strnum = __commonJS({
  "node_modules/strnum/strnum.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/ignoreAttributes.js
var require_ignoreAttributes = __commonJS({
  "node_modules/fast-xml-parser/src/ignoreAttributes.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js
var require_OrderedObjParser = __commonJS({
  "node_modules/fast-xml-parser/src/xmlparser/OrderedObjParser.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/xmlparser/node2json.js
var require_node2json = __commonJS({
  "node_modules/fast-xml-parser/src/xmlparser/node2json.js"(exports) {
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

// node_modules/fast-xml-parser/src/xmlparser/XMLParser.js
var require_XMLParser = __commonJS({
  "node_modules/fast-xml-parser/src/xmlparser/XMLParser.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/xmlbuilder/orderedJs2Xml.js
var require_orderedJs2Xml = __commonJS({
  "node_modules/fast-xml-parser/src/xmlbuilder/orderedJs2Xml.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/xmlbuilder/json2xml.js
var require_json2xml = __commonJS({
  "node_modules/fast-xml-parser/src/xmlbuilder/json2xml.js"(exports, module) {
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

// node_modules/fast-xml-parser/src/fxp.js
var require_fxp = __commonJS({
  "node_modules/fast-xml-parser/src/fxp.js"(exports, module) {
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

// ../sigma-data-model-mcp/build/tableau.js
var import_fast_xml_parser = __toESM(require_fxp(), 1);

// ../sigma-data-model-mcp/build/sigma-ids.js
var SIGMA_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
var _usedIds = /* @__PURE__ */ new Set();
var _idCounter = 0;
function encodeBase62(n, len) {
  let x = n, s = "";
  while (x > 0) {
    s = SIGMA_CHARS[x % 62] + s;
    x = Math.floor(x / 62);
  }
  return s.padStart(len, SIGMA_CHARS[0]);
}
function fnv1a32(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
var NS_MODULUS = 62 ** 4;
var NS_BLOCK = 1e6;
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
function resetIds(seed) {
  _usedIds.clear();
  _idCounter = seed == null ? 0 : fnv1a32(seed) % NS_MODULUS * NS_BLOCK;
}
function clampId(id, max = 64) {
  if (id.length <= max)
    return id;
  const suffix = "~" + encodeBase62(fnv1a32(id) % 62 ** 6, 6);
  return id.slice(0, max - suffix.length) + suffix;
}
// LOCAL PATCH (illegal controlId characters, 2026-08 bisect): the canonical
// Sigma OpenAPI declares `controlId` as a bare string with NO documented
// charset/pattern constraint, so this is not "the" charset — it is a
// conservative SAFE SUBSET ([a-zA-Z0-9_-], <=64 chars) chosen because
// restricting to a narrower set than the API actually accepts can never
// cause a rejection, while a raw Tableau parameter caption CAN contain
// characters a live DM POST rejects (observed: a caption using Tableau's own
// pipe-delimited multi-value convention, e.g. "MultiParam | Category", was
// rejected once the unstripped "|" reached a controlId). Collapses every run
// of whitespace or other non-safe characters to a single "-", trims leading/
// trailing "-", then reuses clampId's existing hash-suffixed truncation so a
// long id cannot silently collide with another long id it was truncated
// against. NOTE: shrinking the charset makes DISTINCT captions more likely
// to normalize to the SAME id (e.g. "A | B" and "A @ B" both collapse to
// "A-B") — callers must still run their controlId through a dedupe pass
// (see the "controlId dedupe" block below) before treating the result as
// collision-free.
function sanitizeControlId(raw) {
  const cleaned = String(raw || "").replace(/\s+/g, "-").replace(/[^a-zA-Z0-9_-]+/g, "-").replace(/-{2,}/g, "-").replace(/^-+|-+$/g, "");
  return clampId(cleaned || "control");
}
function sigmaShortId(len = 10) {
  let id;
  do {
    id = encodeBase62(++_idCounter, len);
  } while (_usedIds.has(id));
  _usedIds.add(id);
  return id;
}
function sigmaInodeId(identifier, casing = "upper") {
  const phys = casing === "lower" ? identifier.toLowerCase() : identifier.toUpperCase();
  return clampId(`inode-${sigmaShortId(22)}/${phys}`);
}
function sigmaDisplayName(s) {
  const normalized = (s || "").replace(/([a-z])([A-Z])/g, "$1_$2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2").replace(/([A-Za-z])([0-9])/g, "$1_$2").replace(/([0-9])([A-Za-z])/g, "$1_$2");
  const words = normalized.toLowerCase().split(/[_\s/-]+/).filter(Boolean);
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
function buildDerivedElements(elements, warnings) {
  const derived = [];
  const warnSlash = (dispName, where) => {
    if (warnings)
      warnings.push(`⚠ Column "${dispName}" contains "/" in its display name — ambiguous against Sigma's [Element/Column] path syntax; DROPPED from the derived ${where}. Rename the column (remove the slash) in Tableau or the DM spec to carry it through.`);
  };
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
      if (dispName.includes("/")) {
        warnSlash(dispName, `"${derivedName}" element (own column)`);
        continue;
      }
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
        // A target can itself carry columns synthesized through ANOTHER
        // relationship (hub parent with multiple child facts). Their captions
        // carry the sibling table suffix. Pulling them into this derived view
        // makes child A reach sideways through the parent into child B — an
        // invalid sibling-fact Lookup. Do this after display-name recovery so a
        // legitimate slash-named caption still reaches warnSlash below.
        const relatedSuffix = dispName.match(/\s+\(([^()]+)\s+\([^()]+\)\)\s*$/);
        const targetBaseName = tgtEl.name || (tgtEl.source?.path || []).slice(-1)[0] || "";
        if (relatedSuffix && relatedSuffix[1].toUpperCase() !== String(targetBaseName).toUpperCase())
          continue;
        if (dispName.includes("/")) {
          warnSlash(dispName, `"${derivedName}" element (related column via ${rel.name})`);
          continue;
        }
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

// ../sigma-data-model-mcp/build/formulas.js
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
// Coalesce is deliberately NOT in the text set: its type follows its args, and
// the null-guard idiom Coalesce(x, 0) is numeric — counting it as text turned
// ZN(a)+ZN(b) addition into silent string concat (live-verified field bug).
// Instead _isTextOperand recurses into Coalesce's args, so string-guard chains
// (Coalesce([first], "x") + …) still convert + → & while numeric guards keep +.
var _TEXT_FN_RE = /(?:Concat|Text|Left|Right|Mid|Substring|Substr|Upper|Lower|Trim|Replace|MonthName|WeekdayName|DateName|Proper)$/i;
function _splitTopLevelArgs(s) {
  const args = [];
  let depth = 0, quote = null, buf = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) {
      buf += ch;
      if (ch === quote && s[i - 1] !== "\\")
        quote = null;
      continue;
    }
    if (ch === '"' || ch === "'")
      quote = ch;
    else if (ch === "(" || ch === "[")
      depth++;
    else if (ch === ")" || ch === "]") {
      depth--;
      // Depth going negative means s is not a single call's arg list (e.g. an
      // unwrapped compound like `Coalesce(a, 0) = X`) — report no args.
      if (depth < 0)
        return [];
    } else if (ch === "," && depth === 0) {
      args.push(buf.trim());
      buf = "";
      continue;
    }
    buf += ch;
  }
  if (buf.trim())
    args.push(buf.trim());
  return args;
}
function stripOuterParens(s) {
  s = s.trim();
  while (s.length > 1 && s.startsWith("(") && s.endsWith(")")) {
    let depth = 0, quote = "", inBracket = false, wraps = true;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (inBracket) {
        if (c === "]")
          inBracket = false;
        continue;
      }
      if (quote) {
        if (c === quote)
          quote = "";
        continue;
      }
      if (c === "[") {
        inBracket = true;
        continue;
      }
      if (c === "'" || c === '"') {
        quote = c;
        continue;
      }
      if (c === "(")
        depth++;
      else if (c === ")") {
        depth--;
        if (depth === 0 && i < s.length - 1) {
          wraps = false;
          break;
        }
      }
    }
    if (!wraps || depth !== 0)
      break;
    s = s.slice(1, -1).trim();
  }
  return s;
}
function _isTextOperand(op, isTextRef) {
  let s = stripOuterParens(op.trim());
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
  if (fn && /^Coalesce$/i.test(fn[1])) {
    const args = _splitTopLevelArgs(s.slice(s.indexOf("(") + 1, -1));
    return args.some((a) => _isTextOperand(a, isTextRef));
  }
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
  // trig + angle conversion — same names/arg-order in Sigma (live-verified 2026-07-10, bead tt3z.3)
  "SIN": "Sin",
  "COS": "Cos",
  "TAN": "Tan",
  "COT": "Cot",
  "ASIN": "Asin",
  "ACOS": "Acos",
  "ATAN": "Atan",
  "ATAN2": "Atan2",
  "DEGREES": "Degrees",
  "RADIANS": "Radians",
  // PROPER (title-case) — live-verified Sigma Proper() (bead tt3z.3)
  "PROPER": "Proper",
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
  // NOTE: no 'WEEK' entry — Sigma has no Week() function; WEEK(date) is rewritten
  // to DatePart("week", date) below (verified via docs + live query 2026-07-10).
  "QUARTER": "Quarter",
  "DATE": "Date",
  // DATETIME(x) → Date(x): Sigma has no Datetime() (absent from the function
  // index) — Date() is the documented cast to the datetime type.
  "DATETIME": "Date",
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
  "SPLIT": "SplitPart",
  // null-guard — native Sigma Zn (docs/zn). Name-map, not an arg regex: the old
  // single-paren Coalesce($1, 0) rewrite emitted malformed Coalesce(Sum([x], 0))
  // for the dominant field idiom ZN(AGG(...)).
  "ZN": "Zn"
};
var SIGMA_CHART_ONLY_WINDOW_RE = /\b(?:Cumulative(?:Sum|Avg|Min|Max|Count)|Moving(?:Sum|Avg|Min|Max|Count|StdDev|Variance|Corr)|RankDense|RankPercentile|Rank|PercentOfTotal|RowNumber|Lag|Lead)\s*\(/;
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
// WINDOW_CORR / WINDOW_VAR / WINDOW_COUNT are NOT listed — Sigma ships
// MovingCorr/MovingVariance/MovingCount (function index, verified 2026-07-25),
// mapped below. The population variants (VARP/COVARP/STDEVP) stay: no Moving*Pop.
function tableauWindowUntranslatable(formula) {
  const m = (formula || "").match(/\b(WINDOW_MEDIAN|WINDOW_PERCENTILE|WINDOW_COVARP?|WINDOW_VARP|WINDOW_STDEVP|PREVIOUS_VALUE|SIZE)\s*\(/i);
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
  m = f.match(new RegExp(`^WINDOW_(SUM|AVG|MIN|MAX|STDEV|COUNT|VAR)\\s*\\(\\s*${_TC_AGG_EXPR}\\s*,\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)$`, "i"));
  if (m) {
    const back = parseInt(m[4], 10);
    const fwd = parseInt(m[5], 10);
    if (back <= 0 && fwd >= 0) {
      // COUNT/VAR → MovingCount/MovingVariance: present in the Sigma function
      // index (verified 2026-07-25); previously mis-listed as untranslatable.
      const movMap = {
        SUM: "MovingSum",
        AVG: "MovingAvg",
        MIN: "MovingMin",
        MAX: "MovingMax",
        STDEV: "MovingStdDev",
        COUNT: "MovingCount",
        VAR: "MovingVariance"
      };
      const fn = movMap[m[1].toUpperCase()];
      const args = fwd === 0 ? `${-back}` : `${-back}, ${fwd}`;
      return { formula: `${fn}(${_tcAgg(m[2], m[3])}, ${args})`, kind: "moving" };
    }
    return null;
  }
  // WINDOW_CORR(AGG([x]), AGG([y]), -n, m) → MovingCorr(Agg([x]), Agg([y]), n[, m])
  // (two-expression form; offsets must span the current row, like the other
  // Moving* mappings). Offset-less WINDOW_CORR is a whole-partition corr with
  // no validated Sigma window shape — it falls to the loud not-converted flag.
  m = f.match(new RegExp(`^WINDOW_CORR\\s*\\(\\s*${_TC_AGG_EXPR}\\s*,\\s*${_TC_AGG_EXPR}\\s*,\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)$`, "i"));
  if (m) {
    const back = parseInt(m[5], 10);
    const fwd = parseInt(m[6], 10);
    if (back <= 0 && fwd >= 0) {
      const args = fwd === 0 ? `${-back}` : `${-back}, ${fwd}`;
      return { formula: `MovingCorr(${_tcAgg(m[1], m[2])}, ${_tcAgg(m[3], m[4])}, ${args})`, kind: "moving" };
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
function tableauIfToSigma(f, lits) {
  return f.replace(/\bIF\b([\s\S]+?)\bEND\b/gi, (match) => {
    let inner = match.replace(/^\s*IF\s*/i, "").replace(/\s*END\s*$/i, "");
    const elseIdx = inner.search(/\bELSE\b(?!\s*IF\b)/i);
    let elseVal = "null";
    if (elseIdx >= 0) {
      elseVal = _tableauRecurse(inner.slice(elseIdx).replace(/^\s*ELSE\s*/i, "").trim(), lits);
      inner = inner.slice(0, elseIdx);
    }
    const parts = inner.split(/\bELSEIF\b/i);
    let result = elseVal;
    for (let i = parts.length - 1; i >= 0; i--) {
      const thenParts = parts[i].split(/\bTHEN\b/i);
      if (thenParts.length < 2)
        continue;
      const cond = _tableauRecurse(thenParts[0].trim(), lits);
      const val = _tableauRecurse(thenParts[1].trim(), lits);
      result = "If(" + cond + ", " + val + ", " + result + ")";
    }
    return result;
  });
}
function tableauCaseToSigma(f, lits) {
  return f.replace(/\bCASE\b([\s\S]+?)\bEND\b/gi, (match, body) => {
    const elseIdx = body.search(/\bELSE\b/i);
    let elseVal = "null";
    let whenBody = body;
    if (elseIdx >= 0) {
      elseVal = _tableauRecurse(body.slice(elseIdx).replace(/^\s*ELSE\s*/i, "").trim(), lits);
      whenBody = body.slice(0, elseIdx);
    }
    const fieldMatch = whenBody.match(/^([\s\S]*?)\bWHEN\b/i);
    const field = fieldMatch ? _tableauRecurse(fieldMatch[1].trim(), lits) : "[?]";
    const pairs = whenBody.replace(/^[\s\S]*?\bWHEN\b/i, "").split(/\bWHEN\b/i).filter(Boolean);
    let result = elseVal;
    for (let i = pairs.length - 1; i >= 0; i--) {
      const thenParts = pairs[i].split(/\bTHEN\b/i);
      if (thenParts.length < 2)
        continue;
      result = "If(" + field + " = " + _tableauRecurse(thenParts[0].trim(), lits) + ", " + _tableauRecurse(thenParts[1].trim(), lits) + ", " + result + ")";
    }
    return result;
  });
}
var _TABLEAU_LIT_SQ_RE = /'(?:[^'\\]|\\.)*'/g;
var _TABLEAU_LIT_DQ_RE = /"(?:[^"\\]|\\.)*"/g;
var _TABLEAU_SENTINEL_SRC = "\0(\\d+)";
var _TABLEAU_SENTINEL_RE = / (\d+)/g;
function _maskTableauLiterals(s, lits = []) {
  let out = "";
  let i = 0;
  while (i < s.length) {
    if (s[i] === "[") {
      const close = s.indexOf("]", i + 1);
      if (close !== -1) {
        out += s.slice(i, close + 1);
        i = close + 1;
        continue;
      }
    }
    if (s[i] === "'" || s[i] === '"') {
      const re = s[i] === "'" ? _TABLEAU_LIT_SQ_RE : _TABLEAU_LIT_DQ_RE;
      re.lastIndex = i;
      const m = re.exec(s);
      if (m && m.index === i) {
        out += `\0${lits.push(m[0]) - 1}`;
        i += m[0].length;
        continue;
      }
    }
    out += s[i];
    i++;
  }
  return { masked: out, lits };
}
function _restoreRawTableauLiterals(s, lits) {
  return s.replace(_TABLEAU_SENTINEL_RE, (_m, i) => lits[Number(i)] ?? _m);
}
function _tabLitInner(lits, idxStr) {
  const raw = lits[Number(idxStr)];
  return raw === void 0 ? "" : raw.slice(1, -1).replace(/\\(['"])/g, "$1");
}
function _tabEscapeForSigma(inner) {
  return inner.replace(/"/g, '\\"');
}
function _unmaskTableauLiterals(s, lits) {
  return s.replace(_TABLEAU_SENTINEL_RE, (_m, i) => `"${_tabEscapeForSigma(_tabLitInner(lits, i))}"`);
}
function _tableauRecurse(maskedSlice, lits) {
  const raw = _restoreRawTableauLiterals(maskedSlice, lits);
  const converted = tableauFormulaToSigma(raw);
  const { masked } = _maskTableauLiterals(converted, lits);
  return masked;
}
function tableauFormulaToSigma(formula, warnings) {
  if (!formula || !formula.trim())
    return "";
  const raw0 = stripLineComments(decodeXmlEntities(formula)).trim();
  const { masked, lits } = _maskTableauLiterals(raw0);
  let f = masked;
  if (/^\s*\{/.test(f)) {
    if (warnings)
      warnings.push("\u26A0 LOD expression not converted: " + raw0.slice(0, 60));
    return "/* LOD: " + raw0.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
  }
  {
    const winChart = tableauWindowToSigmaChart(raw0);
    if (winChart) {
      if (warnings)
        warnings.push(`\u2139 Table calc \u2192 ${winChart.formula} \u2014 CHART/grouped-element context ONLY: place in a grouped workbook element (group by the viz dimensions); window functions silently error in data-model calc columns and workbook master calc columns.` + (winChart.note ? " " + winChart.note : ""));
      return winChart.formula;
    }
    const untrans = tableauWindowUntranslatable(raw0);
    if (untrans) {
      if (warnings)
        warnings.push(`\u26A0 Table calculation NOT converted \u2014 ${untrans}() has no Sigma equivalent. Untranslated fragment: ${raw0.slice(0, 120)}`);
      return "/* table calc: " + raw0.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
    }
    if (/^(WINDOW_|RUNNING_|FIRST\(|LAST\(|INDEX\(|RANK\b|RANK_|LOOKUP\(|TOTAL\s*\()/i.test(raw0)) {
      const gt = raw0.match(/^WINDOW_SUM\s*\(\s*(SUM|COUNT|AVG|MIN|MAX)\s*\(\s*(\[[^\]]+\])\s*\)\s*\)$/i);
      if (gt) {
        const aggMap = { SUM: "Sum", COUNT: "Count", AVG: "Avg", MIN: "Min", MAX: "Max" };
        return "GrandTotal(" + (aggMap[gt[1].toUpperCase()] || gt[1]) + "(" + gt[2] + "))";
      }
      if (warnings)
        warnings.push(`\u26A0 Table calculation not converted. Untranslated fragment: ${raw0.slice(0, 120)}`);
      return "/* table calc: " + raw0.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
    }
  }
  if (/\bCOVARP?\s*\(/i.test(f)) {
    if (warnings)
      warnings.push(`\u26A0 COVAR/COVARP has no Sigma equivalent \u2014 not converted. Fragment: ${raw0.slice(0, 120)}`);
    return "/* no Sigma equivalent: " + raw0.replace(/\/\*/g, "").replace(/\*\//g, "") + " */";
  }
  // (ZN → Zn happens in the TABLEAU_FUNC_MAP pass — nesting-safe name rename.)
  f = f.replace(/\bIFNULL\s*\(/gi, "Coalesce(").replace(/\bIFERROR\s*\(/gi, "Coalesce(");
  f = f.replace(/\bISNULL\s*\(/gi, "IsNull(");
  f = f.replace(/\bCOUNT\s*\(([^)]+)\)/gi, (m, arg) => "CountIf(IsNotNull(" + arg.trim() + "))");
  f = f.replace(/\bCOUNTD\s*\(/gi, "CountDistinct(");
  f = f.replace(/\bATTR\s*\(([^)]+)\)/gi, "$1");
  f = tableauInToSigma(f);
  f = tableauIfToSigma(f, lits);
  f = f.replace(/\bIIF\s*\(/gi, "If(");
  f = tableauCaseToSigma(f, lits);
  f = f.replace(new RegExp(`\\bDATEPART\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*,\\s*([^)]+)\\)`, "gi"), (m, litIdx, dateArg) => {
    const part = _tabLitInner(lits, litIdx);
    if (!/^\w+$/.test(part))
      return m;
    const p = part.toLowerCase();
    if (p === "week")
      return 'DatePart("week", ' + dateArg.trim() + ")";
    // 'weekday'/'dayofweek' → Weekday(date) — Sigma has no DayOfWeek() (absent
    // from the function index). Sigma Weekday anchors Sunday=1..7; Tableau
    // numbering follows the datasource start-of-week — flag to verify.
    if (p === "weekday" || p === "dayofweek") {
      if (warnings)
        warnings.push(`⚠ DATEPART('${p}') → Weekday() — verify numbering: Sigma anchors Sunday=1..7; Tableau follows the datasource start-of-week.`);
      return "Weekday(" + dateArg.trim() + ")";
    }
    const partMap = {
      year: "Year",
      month: "Month",
      day: "Day",
      hour: "Hour",
      minute: "Minute",
      second: "Second",
      quarter: "Quarter"
    };
    const fn = partMap[p];
    return fn ? fn + "(" + dateArg.trim() + ")" : m;
  });
  f = f.replace(new RegExp(`\\bDATENAME\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*,\\s*([^,)]+)(?:,[^)]*)?\\)`, "gi"), (m, litIdx, dateArg) => {
    const part = _tabLitInner(lits, litIdx);
    if (!/^\w+$/.test(part))
      return m;
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
        // via DatePart("week", …) — Sigma has no Week() (see the WEEK note above)
        return 'Text(DatePart("week", ' + arg + "))";
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
  f = f.replace(new RegExp(`\\bDATETRUNC\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*,`, "gi"), (_m, litIdx) => `DateTrunc("${_tabEscapeForSigma(_tabLitInner(lits, litIdx))}",`);
  // Start-of-week literal — DATETRUNC('week', d, 'monday') 3rd arg / 4-arg
  // DATEDIFF('week', a, b, 'monday'): Sigma DateTrunc/DateDiff have no
  // start-of-week slot, so the literal is dropped — but never silently (week
  // boundaries then follow the warehouse week start; silent drift shipped in
  // the field). Scoped to those two callers via a balanced-paren walk back to
  // the enclosing call, so e.g. Contains([Day], 'monday') keeps its argument.
  // Local patch, ported onto d839036's sentinel-masked text (was raw-quote
  // regex text before the masking rewrite): the walk reads `whole` (masked
  // `f`) which never contains an unescaped paren inside a sentinel, so the
  // balance count is unaffected by masking.
  f = f.replace(new RegExp(`,\\s*${_TABLEAU_SENTINEL_SRC}\\s*\\)`, "gi"), (m, litIdx, off, whole) => {
    const val = _tabLitInner(lits, litIdx);
    if (!/^(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)$/i.test(val))
      return m;
    let fn = "", depth = 0;
    for (let i = off; i >= 0; i--) {
      const c = whole[i];
      if (c === ")")
        depth++;
      else if (c === "(") {
        if (depth === 0) {
          const h = whole.slice(0, i).match(/([A-Za-z_][A-Za-z0-9_]*)\s*$/);
          fn = h ? h[1] : "";
          break;
        }
        depth--;
      }
    }
    if (!/^(?:datetrunc|datediff)$/i.test(fn))
      return m;
    if (warnings)
      warnings.push(`⚠ ${fn.toUpperCase()} start-of-week '${val}' dropped — Sigma ${/^datetrunc$/i.test(fn) ? "DateTrunc" : "DateDiff"} has no start-of-week argument; week boundaries follow the warehouse week start. Verify week-grain results.`);
    return ")";
  });
  f = f.replace(new RegExp(`\\bDATEADD\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*,`, "gi"), (_m, litIdx) => `DateAdd("${_tabEscapeForSigma(_tabLitInner(lits, litIdx))}",`);
  f = f.replace(new RegExp(`\\bDATEDIFF\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*,`, "gi"), (_m, litIdx) => `DateDiff("${_tabEscapeForSigma(_tabLitInner(lits, litIdx))}",`);
  f = f.replace(/\bWEEK\s*\(\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/gi, 'DatePart("week", $1)');
  f = f.replace(/\bSTDEVP\s*\(([^()]+(?:\([^()]*\)[^()]*)*)\)/gi, "Sqrt(VariancePop($1))");
  f = f.replace(new RegExp(`\\bDATEPARSE\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*,\\s*([^()]+(?:\\([^()]*\\)[^()]*)*)\\)`, "gi"), (_m, litIdx, str) => {
    const fmtRaw = _tabLitInner(lits, litIdx);
    const sf = fmtRaw.replace(/yyyy/g, "%Y").replace(/yy/g, "%y").replace(/MMMM/g, "%B").replace(/MMM/g, "%b").replace(/MM/g, "%m").replace(/dd/g, "%d").replace(/HH/g, "%H").replace(/hh/g, "%I").replace(/mm/g, "%M").replace(/ss/g, "%S");
    if (warnings)
      warnings.push("\u26A0 DATEPARSE format translated to strftime tokens \u2014 verify the pattern resolves on your warehouse.");
    return `DateParse(${str.trim()}, "${sf}")`;
  });
  f = f.replace(/\bUSERNAME\s*\(\s*\)/gi, "CurrentUserEmail()");
  f = f.replace(new RegExp(`\\bISMEMBEROF\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*\\)`, "gi"), (_m, litIdx) => `CurrentUserInTeam("${_tabEscapeForSigma(_tabLitInner(lits, litIdx))}")`);
  f = f.replace(new RegExp(`\\bUSERATTRIBUTE\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*\\)`, "gi"), (_m, litIdx) => `CurrentUserAttributeText("${_tabEscapeForSigma(_tabLitInner(lits, litIdx))}")`);
  f = f.replace(new RegExp(`\\bISUSERNAME\\s*\\(\\s*${_TABLEAU_SENTINEL_SRC}\\s*\\)`, "gi"), (_m, litIdx) => `(CurrentUserEmail() = "${_tabEscapeForSigma(_tabLitInner(lits, litIdx))}")`);
  f = f.replace(/\bSQUARE\s*\(\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/gi, "Power($1, 2)");
  f = f.replace(/\bSPACE\s*\(\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/gi, 'Repeat(" ", $1)');
  for (const [tab, sig] of Object.entries(TABLEAU_FUNC_MAP)) {
    f = f.replace(new RegExp("\\b" + tab + "\\s*\\(", "gi"), sig + "(");
  }
  f = f.replace(/\bNOT\b/g, "Not").replace(/\bAND\b/g, "and").replace(/\bOR\b/g, "or");
  f = f.replace(/\bTRUE\b/gi, "True").replace(/\bFALSE\b/gi, "False").replace(/\bNULL\b/gi, "null");
  f = f.replace(/\[([A-Z][A-Z0-9_]{2,})\]/g, (match, colName) => {
    if (colName === colName.toLowerCase() || colName.includes(" "))
      return match;
    return "[" + sigmaDisplayName(colName) + "]";
  });
  f = _unmaskTableauLiterals(f, lits);
  f = tableauTextConcatToSigma(f);
  if (warnings && TABLEAU_TABLE_CALC_TOKEN_RE.test(f)) {
    warnings.push(`\u26A0 Table-calc function embedded in a larger expression \u2014 NOT translated in place. Untranslated fragment: ${f.slice(0, 120)}`);
  }
  if (warnings) {
    const masked2 = f.replace(/"[^"]*"/g, '""').replace(/\[[^\]]*\]/g, "[]");
    const unmapped = /* @__PURE__ */ new Set();
    const scan = /\b([A-Z][A-Z0-9_]+)\s*\(/g;
    let mm;
    while ((mm = scan.exec(masked2)) !== null) {
      const fn = mm[1];
      if (TABLEAU_TABLE_CALC_TOKEN_RE.test(fn + "("))
        continue;
      unmapped.add(fn);
    }
    if (unmapped.size) {
      warnings.push(`\u26A0 Unmapped Tableau function(s) passed through unconverted: ${[...unmapped].join(", ")} \u2014 no validated Sigma equivalent yet. Rewrite manually; left as-is they error at query time.`);
    }
  }
  return f.trim();
}
function tableauIsAggregate(formula) {
  return /\b(SUM|AVG|COUNT|COUNTD|MAX|MIN|MEDIAN|STDEV|STDEVP|VAR|VARP|PERCENTILE|CORR|ATTR)\s*\(/i.test(formula);
}
function tableauFormulaIsRls(formula) {
  return /\b(USERNAME|FULLNAME|USERDOMAIN|ISMEMBEROF|ISUSERNAME|USERATTRIBUTE)\s*\(/i.test(formula || "");
}

// ../sigma-data-model-mcp/build/tableau.js
function paramControlId(rawName) {
  return clampId("ctl-" + rawName.replace(/[^a-zA-Z0-9]+/g, "-").replace(/^-|-$/g, "").toLowerCase());
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
function isExtractPlaceholderRel(rel) {
  if (!rel)
    return false;
  const table = attr(rel, "table");
  const name = attr(rel, "name");
  if (table === "[Extract].[Extract]" || table === "[sqlproxy]")
    return true;
  if ((name === "Extract" || name === "sqlproxy") && !rel.columns)
    return true;
  return false;
}
function pickRootRelation(conn) {
  const rels = connRelations(conn);
  if (rels.length <= 1)
    return rels[0] || null;
  const meaningful = rels.find((r) => {
    const t = attr(r, "type") || "table";
    if (t === "text" || t === "join" || t === "collection")
      return true;
    return !isExtractPlaceholderRel(r);
  });
  return meaningful || rels[0];
}
function allConnections(connVal) {
  const out = [];
  const visit = (c) => {
    if (!c)
      return;
    if (Array.isArray(c)) {
      c.forEach(visit);
      return;
    }
    if (typeof c !== "object")
      return;
    out.push(c);
    if (c.connection)
      visit(c.connection);
    const ncs = c["named-connections"];
    if (ncs)
      for (const nc of asArray(ncs["named-connection"] || []))
        visit(nc?.connection);
  };
  visit(connVal);
  return out;
}
function effectiveConnection(connVal) {
  const conns = allConnections(connVal);
  if (conns.length === 0)
    return Array.isArray(connVal) ? connVal[0] : connVal;
  const meaningful = conns.find((c) => connRelations(c).some((r) => {
    const t = attr(r, "type") || "table";
    if (t === "text" || t === "join" || t === "collection")
      return true;
    return !isExtractPlaceholderRel(r);
  }));
  return meaningful || conns[0];
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
// LOCAL PATCH (FIXED-LOD raw-SQL dialect gap, 2026-08 bisect): the general
// calc translator (tableauFormulaToSigma) maps Tableau function names to
// Sigma's OWN DM-formula language (e.g. DATETRUNC -> DateTrunc(...) —
// verified in refs/functions.json), but that translation target is Sigma
// formula syntax, not SQL, so it cannot be reused verbatim here. FIXED-LOD
// (and window-helper) lowering instead builds a raw Custom-SQL statement via
// _tableauExprToSql, which previously did ONLY structural rewriting
// (quote-style, IF/END -> CASE WHEN/END) and copied every function CALL name
// through unchanged — emitting invalid Snowflake SQL like
// DATETRUNC('month', ...) (Snowflake's function is DATE_TRUNC). This map is
// the general fix: every Tableau function name that has a Snowflake SQL
// equivalent with an IDENTICAL argument count/order (a safe 1:1 name swap,
// never a restructure) is renamed at the point a function CALL is recognized
// (name immediately followed by "(" — never a bare column token, which
// by this point in the pipeline is already an unbracketed identifier and
// could otherwise collide with a short map key like LEN/MID).
//
// Deliberately NOT included (name swap alone would be WRONG, not just
// untranslated, because the calling convention differs): DATENAME (returns a
// string; Snowflake has no same-signature equivalent, needs
// TO_CHAR/MONTHNAME restructuring), FIND (Tableau FIND(string, substring) vs
// Snowflake POSITION(substring, string) — argument ORDER is reversed),
// ISNULL (Tableau function-call form vs SQL's "x IS NULL" operator form).
// DATEADD and DATEDIFF are NOT in the map because their Tableau and
// Snowflake forms already share the same name AND argument order — no
// rewrite needed. Any Tableau function not covered here still passes through
// unchanged (same behavior as before this patch), so remaining gaps fail
// loudly as invalid SQL rather than silently miscompiling.
var TABLEAU_TO_SQL_FUNC_MAP = {
  DATETRUNC: "DATE_TRUNC",
  DATEPART: "DATE_PART",
  IIF: "IFF",
  LEN: "LENGTH",
  MID: "SUBSTR"
};
function _tableauExprToSql(s) {
  s = s.replace(/"([^"]*)"/g, (_m, inner) => `'${inner.replace(/'/g, "''")}'`);
  if (/\bIF\b/i.test(s) && /\bEND\b/i.test(s)) {
    s = s.replace(/\bELSE\s+IF\b/gi, "WHEN").replace(/\bELSEIF\b/gi, "WHEN").replace(/\bIF\b/gi, "CASE WHEN");
  }
  s = s.replace(/\b([A-Za-z_][A-Za-z0-9_]*)(\s*\()/g, (m, fn, paren) => {
    const sqlFn = TABLEAU_TO_SQL_FUNC_MAP[fn.toUpperCase()];
    return sqlFn ? sqlFn + paren : m;
  });
  return s;
}
function _tableauInnerToSql(expr) {
  let s = expr;
  s = s.replace(/\bZN\s*\(([^()]+)\)/gi, "$1");
  s = s.replace(/\[([^\]]+)\]/g, (_m, name) => name.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase());
  s = _tableauExprToSql(s);
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
function _stripOuterAggAroundLod(formula) {
  const m = formula.trim().match(/^(SUM|MAX|MIN|AVG|COUNT|COUNTD|ATTR)\s*\(\s*(\{\s*(?:FIXED|INCLUDE|EXCLUDE)[\s\S]*\})\s*\)$/i);
  if (!m)
    return null;
  const inner = m[2].trim();
  if (!/^\{[\s\S]*\}$/.test(inner))
    return null;
  return { aggFunc: m[1].toUpperCase(), inner };
}
function _repointCustomSqlSchema(sql, oldDb, oldSchema, newDb, newSchema) {
  if (!sql || !newDb || !newSchema || !oldDb || !oldSchema)
    return sql;
  if (oldDb.toUpperCase() === newDb.toUpperCase() && oldSchema.toUpperCase() === newSchema.toUpperCase())
    return sql;
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const seg = (s) => `(?:"${esc(s)}"|${esc(s)})`;
  const re = new RegExp(`${seg(oldDb)}\\s*\\.\\s*${seg(oldSchema)}\\s*\\.`, "gi");
  return sql.replace(re, `${newDb}.${newSchema}.`);
}
function _isTableauVirtualField(name) {
  return (name || "").replace(/^\[|\]$/g, "").trim().startsWith(":");
}
function _windowInnerToSql(expr) {
  let s = expr;
  s = s.replace(/\bZN\s*\(([^()]+)\)/gi, "$1");
  s = s.replace(/\[([^\]]+)\]/g, (_m, name) => name.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase());
  s = _tableauExprToSql(s);
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
// LOCAL PATCH (#693): FIXED-LOD/window-helper raw-SQL emits GROUP-BY dimension
// aliases straight from _resolveDimDisplayName2's `physicalUpper` — which by
// design only collapses WHITESPACE (never sanitises other characters), so it
// stays byte-for-byte aligned with the real warehouse column and keeps
// resolving through quotePhysToken()/sqlExactByUpper() below. When the
// physical name itself carries a character bare SQL can't take (a hyphen —
// "Sub-Category", "Year-over-Year", "Ship-Mode" are all real Tableau
// captions; same for embedded spaces or other punctuation), that un-mangled
// name was reused BARE as the emitted `AS` alias, producing e.g.
// `SUB_CATEGORY AS SUB-CATEGORY` — Snowflake reads the bare hyphen as a
// minus operator (issue #693). Quote — never sanitise — so the emitted alias
// and the [Custom SQL/<name>] formula reference built from the SAME string
// elsewhere in this file keep agreeing byte-for-byte: quoting changes the
// alias's legal-SQL REPRESENTATION, not its VALUE, and every name reaching
// this helper is already upper-cased by _resolveDimDisplayName2, so a quoted
// alias and Snowflake's own unquoted-identifier case-folding land on the
// SAME output column name whenever quoting wasn't actually required.
// Conditional (not _qid's unconditional quoting) to leave the common,
// already-safe-bare-identifier case byte-identical to today
// (test-lod-sql-quoting.rb Part B pins `AS CUSTOMER_REF_ID` bare — quoting it
// unconditionally would needlessly change already-correct output). Charset
// matches scripts/lib/sql_ident_check.rb's BARE_IDENT_RE (the Ruby-side
// pre-POST gate's legality oracle) so both layers agree on "safe bare".
var _qidIfNeeded = (name) => /^[A-Za-z_][A-Za-z0-9_$]*$/.test(String(name)) ? name : _qid(name);
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
function unescapeCustomSqlEntities(s) {
  const decodeOnce = (t) => t.replace(/&#x([0-9a-fA-F]+);/g, (_m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (_m, d) => String.fromCodePoint(parseInt(d, 10))).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
  let out = s;
  for (let i = 0; i < 5; i++) {
    const next = decodeOnce(out);
    if (next === out)
      break;
    out = next;
  }
  return out;
}
function collapseDoubledComparisonOps(sql) {
  let rewrites = 0;
  const out = sql.replace(/<{2,}|>{2,}/g, (m) => {
    rewrites++;
    return m[0];
  });
  return { sql: out, rewrites };
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
    mergedElement: { id: fact.id, name: mergedName, kind: "table", source: { connectionId: connId, kind: "sql", statement }, columns: mergedColumns, order, _sqlOrigin: "generated-blend" },
    consumedIds: [fact.id, ...rels.map((r) => r.targetElementId)]
  };
}
var _tableMapping = {};
function resolveTableName(tbl) {
  if (!tbl)
    return tbl;
  const stripped = tbl.replace(/\$+$/, "");
  const up = tbl.toUpperCase();
  const strippedUp = stripped.toUpperCase();
  for (const [k, v] of Object.entries(_tableMapping)) {
    const ku = k.toUpperCase();
    if (k === tbl || k === stripped || ku === up || ku === strippedUp)
      return v;
  }
  return stripped;
}
function extractPath(rel, dbOverride, schOverride, casing = "upper") {
  const rawTable = attr(rel, "table") || attr(rel, "name") || "";
  const cleaned = rawTable.replace(/[\[\]]/g, "").replace(/\s*\([^)]*\)/g, "");
  const fold = (s) => casing === "preserve" ? s : s.toUpperCase();
  const parts = cleaned.split(".").filter(Boolean).map((s) => fold(s).trim()).filter((p) => !/^[0-9A-F]{8}-[0-9A-F]{4}-/i.test(p));
  const stripHash = (s) => s.replace(/_[0-9A-Fa-f]{16,}$/, "");
  let path;
  if (parts.length >= 2) {
    path = [...parts.slice(0, -1), resolveTableName(stripHash(parts[parts.length - 1]))];
  } else if (parts.length === 1) {
    path = [schOverride || "SCHEMA", resolveTableName(stripHash(parts[0]))];
  } else {
    path = [resolveTableName(fold(attr(rel, "name"))) || "UNKNOWN"];
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
var NON_WAREHOUSE_CONN = /* @__PURE__ */ new Set(["sqlproxy", "hyper", "excel-direct", "textscan", "csv", "google-sheets", "virtual-connection", "vconn"]);
function warehouseDbSchemaFromConn(connVal) {
  for (const c of allConnections(connVal)) {
    const cls = (attr(c, "class") || "").toLowerCase();
    if (NON_WAREHOUSE_CONN.has(cls))
      continue;
    const db = attr(c, "dbname") || attr(c, "database") || "";
    const sch = attr(c, "schema") || "";
    if (!db || !sch)
      continue;
    if (/[\\/]/.test(db) || /\.hyper$/i.test(db))
      continue;
    return [db, sch];
  }
  return ["", ""];
}
var CASE_PRESERVING_WH = /\b(databricks|spark|hive|delta)\b/i;
function warehouseCasing(cls) {
  return CASE_PRESERVING_WH.test(cls || "") ? "preserve" : "upper";
}
var NON_WAREHOUSE_CLASS = /* @__PURE__ */ new Set([...NON_WAREHOUSE_CONN, "federated"]);
function warehouseClassFromConn(connVal) {
  for (const c of allConnections(connVal)) {
    const cls = (attr(c, "class") || "").toLowerCase();
    if (!cls || NON_WAREHOUSE_CLASS.has(cls))
      continue;
    return cls;
  }
  return "";
}
function collectTables(rel, tables, nestedUnions) {
  const type = attr(rel, "type") || "table";
  if (type === "table") {
    tables.push({ rel, leftKey: "", rightKey: "", joinType: "", leftKeys: [], rightKeys: [] });
    return;
  }
  if (type === "union" && Array.isArray(nestedUnions)) {
    // W2.16 fix-pass: a union subtree inside a join tree previously vanished
    // here silently (neither branch matched) — the join flattened to its
    // table branches and the union members' rows were DROPPED with elements
    // still emitted. Record it so the join branch can refuse loudly instead.
    nestedUnions.push(attr(rel, "name") || "(unnamed union)");
    return;
  }
  if (type === "join") {
    const joinType = attr(rel, "join") || "left";
    const leftKeys = [], rightKeys = [];
    const walkEq = (expr) => {
      if (!expr || typeof expr !== "object")
        return;
      const kids = asArray(expr.expression || []);
      if (attr(expr, "op") === "=" && kids.length >= 2) {
        const l = attr(kids[0], "op") || "", r = attr(kids[1], "op") || "";
        if (l && r) {
          leftKeys.push(l);
          rightKeys.push(r);
        }
        return;
      }
      for (const k of kids)
        walkEq(k);
    };
    for (const cl of asArray(rel.clause)) {
      for (const e of asArray(cl.expression))
        walkEq(e);
    }
    const leftKey = leftKeys[0] || "", rightKey = rightKeys[0] || "";
    const childRels = asArray(rel.relation);
    if (childRels.length === 2) {
      collectTables(childRels[0], tables, nestedUnions);
      const beforeRight = tables.length;
      collectTables(childRels[1], tables, nestedUnions);
      for (let i = beforeRight; i < tables.length; i++) {
        if (!tables[i].leftKey) {
          tables[i].joinType = joinType;
          tables[i].leftKey = leftKey;
          tables[i].rightKey = rightKey;
          tables[i].leftKeys = leftKeys.slice();
          tables[i].rightKeys = rightKeys.slice();
        }
      }
    } else {
      for (const child of childRels) {
        collectTables(child, tables, nestedUnions);
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
function tryBuildBlendModel(parsed, datasources, dbOverride, schOverride, connId, warehouseType = "") {
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
  const [pDb, pSch] = warehouseDbSchemaFromConn(primary.ds?.connection);
  const pCasing = warehouseCasing(warehouseType || warehouseClassFromConn(primary.ds?.connection));
  const pPath = extractPath(primaryRel, dbOverride || pDb, schOverride || pSch, pCasing);
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
    const [sDb, sSch] = warehouseDbSchemaFromConn(link.sec.ds?.connection);
    const sCasing = warehouseCasing(warehouseType || warehouseClassFromConn(link.sec.ds?.connection));
    const sPath = extractPath(connRelations(link.sec.ds.connection)[0], dbOverride || sDb, schOverride || sSch, sCasing);
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
function buildMultiDatasourceModel(xmlContent, options, datasources) {
  const dataElements = [];
  const controls = [];
  const controlNames = /* @__PURE__ */ new Set();
  const workbookPatterns = [];
  const patternKeys = /* @__PURE__ */ new Set();
  const security = [];
  const parameters = [];
  const paramNames = /* @__PURE__ */ new Set();
  const warnings = [];
  const usedElementNames = /* @__PURE__ */ new Set();
  const perDs = [];
  datasources.forEach((dsMeta, i) => {
    const sub = convertTableauToSigma(xmlContent, { ...options, datasourceIndex: i, __multiDsChild: true });
    const els = sub.model?.pages?.[0]?.elements || [];
    let kept = 0;
    for (const el of els) {
      if (el.kind === "control") {
        const key = String(el.controlId ?? el.name ?? el.id);
        if (!controlNames.has(key)) {
          controlNames.add(key);
          controls.push(el);
        }
        continue;
      }
      if (el.name && usedElementNames.has(el.name)) {
        const suffix = (dsMeta.caption || dsMeta.name || `DS${i + 1}`).replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "") || `DS${i + 1}`;
        const newName = `${el.name}_${suffix}`;
        const oldRef = `[${el.name}/`, newRef = `[${newName}/`;
        const rw = (s) => typeof s === "string" ? s.split(oldRef).join(newRef) : s;
        for (const c of el.columns || [])
          if (c.formula)
            c.formula = rw(c.formula);
        for (const m of el.metrics || [])
          if (m.formula)
            m.formula = rw(m.formula);
        el.name = newName;
      }
      if (el.name)
        usedElementNames.add(el.name);
      dataElements.push(el);
      kept++;
    }
    for (const p of sub.workbookPatterns || []) {
      const k = `${p.kind}::${p.name}`;
      if (!patternKeys.has(k)) {
        patternKeys.add(k);
        workbookPatterns.push(p);
      }
    }
    for (const s of sub.security || [])
      security.push(s);
    for (const p of sub.parameters || []) {
      const k = String(p.name ?? p.id);
      if (!paramNames.has(k)) {
        paramNames.add(k);
        parameters.push(p);
      }
    }
    perDs.push(`${dsMeta.caption || dsMeta.name} (${kept} element${kept === 1 ? "" : "s"})`);
  });
  warnings.unshift(`\u2139 Multi-datasource workbook: built a MULTI-ELEMENT data model \u2014 one element set per independent datasource, so no source's columns are dropped. Datasources: ${perDs.join("; ")}. No cross-datasource relationships were inferred; add joins in Sigma if the sources share keys. Charts resolve against their own datasource's element.`);
  const sigmaModel = {
    name: datasources[0]?.name || "Workbook",
    schemaVersion: 1,
    pages: [{ id: sigmaShortId(), name: "Page 1", elements: [...controls, ...dataElements] }]
  };
  const totalCols = dataElements.reduce((s, e) => s + (e.columns?.length || 0), 0);
  return {
    model: sigmaModel,
    warnings,
    ...security.length ? { security } : {},
    ...workbookPatterns.length ? { workbookPatterns } : {},
    ...parameters.length ? { parameters } : {},
    stats: {
      datasources: datasources.length,
      elements: dataElements.length,
      columns: totalCols,
      metrics: 0,
      relationships: 0
    }
  };
}
function firstTopLevelSelectIndex(stmt) {
  let depth = 0;
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
    if (depth === 0 && /^SELECT\b/i.test(stmt.slice(i)))
      return i;
  }
  return -1;
}
function convertTableauToSigma(xmlContent, options = {}) {
  if (!options.__multiDsChild) {
    resetIds(`ds${options.datasourceIndex ?? 0}\0${xmlContent}`);
  }
  const { connectionId = "", database = "", schema = "", datasourceIndex = 0, tableMapping = {}, factTable = "", tableRowCounts = null } = options;
  _tableMapping = tableMapping || {};
  const dbOverride = database || "";
  const schOverride = schema || "";
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
        const memberAliases = {};
        for (const m of asArray(col.members?.member)) {
          const v = unq(attr(m, "value"));
          const a = unq(attr(m, "alias") || "");
          if (v && a && a !== v)
            memberAliases[v] = a;
        }
        const calcEl = col.calculation;
        parameters.push({
          name: colName.replace(/^\[|\]$/g, ""),
          rawName: rawName.replace(/^\[|\]$/g, ""),
          type: colType,
          domainType,
          members,
          ...Object.keys(memberAliases).length ? { memberAliases } : {},
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
  const blendResult = tryBuildBlendModel(parsed, datasources, dbOverride, schOverride, connectionId || "<CONNECTION_ID>", options.warehouseType || "");
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
  if (!options.__multiDsChild && datasources.length > 1) {
    return buildMultiDatasourceModel(xmlContent, options, datasources);
  }
  const dsIdx = Math.min(datasourceIndex, datasources.length - 1);
  const ds = datasources[dsIdx];
  const rootConn = effectiveConnection(ds.connection);
  const [connDb, connSchema] = warehouseDbSchemaFromConn(ds.connection);
  const dbEff = dbOverride || connDb;
  const schEff = schOverride || connSchema;
  const whCasing = warehouseCasing(options.warehouseType || warehouseClassFromConn(ds.connection));
  const warnings = [];
  const security = [];
  const workbookPatterns = [];
  // Object-model (noodle) state: set by the collection branch below. The
  // elected fact drives factEl (helper FROM anchoring) and the entry/edge
  // inventory drives the structural entitlement-RLS detector.
  let electedFactEl = null;
  let objectModelInfo = null;
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
  let relationshipCoverage = null;
  let joinTableIndex = null;
  const connId = connectionId || "<CONNECTION_ID>";
  const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const colTypeById = {};
  const guidCaption = {};
  const physicalGuidCaption = {};
  const guidOwnerRel = {};
  {
    for (const colsBlock of [
      ...asArray(ds.ds?.cols || []),
      ...asArray(rootConn?.cols || [])
    ]) {
      for (const mp of asArray(colsBlock?.map || [])) {
        const key = (attr(mp, "key") || "").replace(/^\[|\]$/g, "");
        const val = attr(mp, "value") || "";
        const guid = (key.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i) || [])[0];
        const ownerRel = (val.match(/^\[([^\]]+)\]/) || [])[1];
        if (guid && ownerRel)
          guidOwnerRel[guid.toLowerCase()] = ownerRel;
      }
    }
    for (const mr of asArray(rootConn?.["metadata-records"]?.["metadata-record"] || [])) {
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
  const droppedVcJoinRels = [];
  const captionToPhysical = (cap) => cap.trim().replace(/\s+/g, "_").toUpperCase();
  const derivedRelColGuids = /* @__PURE__ */ new Set();
  for (const rel of connRelations(rootConn)) {
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
  const rootRelation = rootConn ? pickRootRelation(rootConn) || null : null;
  if (rootRelation) {
    const relType = attr(rootRelation, "type") || "table";
    if (relType === "table") {
      const path = extractPath(rootRelation, dbEff, schEff, whCasing);
      const tableName = path[path.length - 1] || "";
      const columns = [], order = [];
      for (const col of asArray(rootRelation?.columns?.column || [])) {
        const key = attr(col, "name").toUpperCase();
        if (!key || _isTableauVirtualField(attr(col, "name")))
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
      const nestedUnions = [];
      collectTables(rootRelation, tables, nestedUnions);
      if (nestedUnions.length > 0) {
        // W2.16 fix-pass: refuse-don't-guess. Flattening a join over a union
        // subtree previously emitted only the plain-table branches \u2014 the
        // union members' rows were silently DROPPED (elements still emitted,
        // no warning): the silent-partial-loss class W2.16 exists to kill.
        warnings.push(`\u26A0 Datasource join tree contains ${nestedUnions.length} nested union relation(s) (${nestedUnions.join(", ")}) \u2014 NOT converted: flattening the join would silently drop the union members' rows. NO ELEMENTS EMITTED for this datasource \u2014 model it as a Custom SQL element (join over a UNION ALL subquery), or convert the union's member tables and re-point sources after conversion.`);
      } else if (tables.length === 0) {
        warnings.push("\u26A0 Could not parse join structure");
      } else {
        const elementMap = {};
        for (const t of tables) {
          const path = extractPath(t.rel, dbEff, schEff, whCasing);
          const tableName = path[path.length - 1] || attr(t.rel, "name") || "";
          if (elementMap[tableName])
            continue;
          const columns = [], order = [];
          const guidColIds = {};
          for (const col of asArray(t.rel?.columns?.column || [])) {
            const rawName = attr(col, "name");
            if (!rawName || _isTableauVirtualField(rawName))
              continue;
            const bare = rawName.replace(/^\[|\]$/g, "");
            if (GUID_RE.test(bare)) {
              const g = bare.toLowerCase();
              if (attr(col, "date-parse-format") || col.calculation || derivedRelColGuids.has(g))
                continue;
              const cap = guidCaption[g];
              if (!cap) {
                warnings.push(`\u26A0 ${tableName}: dropped relation column ${bare} \u2014 GUID-named with no caption anywhere in the .twb; emitting it would produce an unresolvable [${tableName}/${bare}] reference.`);
                continue;
              }
              const id2 = sigmaInodeId(captionToPhysical(cap));
              columns.push({ id: id2, formula: `[${tableName}/${cap}]`, name: cap });
              order.push(id2);
              guidColIds[bare.toUpperCase()] = id2;
              continue;
            }
            const key = rawName.toUpperCase();
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
          Object.assign(colIdMap, guidColIds);
          elementMap[tableName] = { element: el, colIdMap };
          elements.push(el);
        }
        const primaryTableName = extractPath(tables[0].rel, dbEff, schEff, whCasing).pop() || "";
        const primaryEntry = elementMap[primaryTableName];
        const resolveJoinKey = (entry, key, tableName) => {
          let colId = entry.colIdMap[key] || entry.colIdMap[sigmaDisplayName(key).toUpperCase()];
          if (colId) {
            const col = entry.element.columns.find((c) => c.id === colId);
            const disp = col?.name || ((col?.formula || "").match(/\/([^\]]+)\]$/) || [])[1] || key;
            return { colId, display: disp };
          }
          if (GUID_RE.test(key)) {
            const cap = guidCaption[key.toLowerCase()];
            if (!cap)
              return { display: key, unresolvedGuid: key };
            const phys = captionToPhysical(cap);
            colId = entry.colIdMap[cap.toUpperCase()] || entry.colIdMap[phys];
            if (!colId) {
              colId = sigmaInodeId(phys);
              entry.element.columns.push({ id: colId, formula: `[${tableName}/${cap}]`, name: cap });
              entry.element.order.push(colId);
              entry.colIdMap[phys] = colId;
              entry.colIdMap[cap.toUpperCase()] = colId;
            }
            entry.colIdMap[key] = colId;
            return { colId, display: cap };
          }
          colId = sigmaInodeId(key);
          entry.element.columns.push({ id: colId, formula: `[${tableName}/${sigmaDisplayName(key)}]` });
          entry.element.order.push(colId);
          entry.colIdMap[key] = colId;
          return { colId, display: sigmaDisplayName(key) };
        };
        const parseKeyTok = (raw) => raw.replace(/^\[|\]$/g, "").split(/[\.\]]\[?/).pop()?.replace(/\]$/, "").toUpperCase() || "";
        for (let i = 1; i < tables.length; i++) {
          const t = tables[i];
          const leftRaw = t.leftKeys && t.leftKeys.length ? t.leftKeys : t.leftKey ? [t.leftKey] : [];
          const rightRaw = t.rightKeys && t.rightKeys.length ? t.rightKeys : t.rightKey ? [t.rightKey] : [];
          if (!leftRaw.length || leftRaw.length !== rightRaw.length)
            continue;
          const tgtName = extractPath(t.rel, dbEff, schEff, whCasing).pop() || "";
          const tgtEntry = elementMap[tgtName];
          if (!primaryEntry || !tgtEntry)
            continue;
          const keys = [];
          const pairDesc = [];
          const badGuids = [];
          for (let k = 0; k < leftRaw.length; k++) {
            const leftKey = parseKeyTok(leftRaw[k]);
            const rightKey = parseKeyTok(rightRaw[k]);
            if (!leftKey || !rightKey)
              continue;
            const src = resolveJoinKey(primaryEntry, leftKey, primaryTableName);
            const tgt = resolveJoinKey(tgtEntry, rightKey, tgtName);
            if (src.unresolvedGuid || tgt.unresolvedGuid || !src.colId || !tgt.colId) {
              for (const g of [src.unresolvedGuid, tgt.unresolvedGuid])
                if (g)
                  badGuids.push(g);
              continue;
            }
            keys.push({ sourceColumnId: src.colId, targetColumnId: tgt.colId });
            pairDesc.push(`${src.display} = ${tgt.display}`);
          }
          if (badGuids.length > 0) {
            droppedVcJoinRels.push({
              source: primaryTableName,
              target: tgtName,
              relName: attr(t.rel, "name") || tgtName,
              unresolved: badGuids
            });
            warnings.push(`\u26A0 DROPPED relationship ${primaryTableName} \u2192 ${tgtName} (${t.joinType || "left"}): join-key GUID(s) ${badGuids.join(", ")} resolve to no caption in the .twb, so the physical join columns cannot be recovered. Columns/metrics referencing the ${tgtName} side will be culled to keep the spec consistent \u2014 wire this relationship manually in Sigma.`);
            continue;
          }
          if (!keys.length)
            continue;
          if (!primaryEntry.element.relationships)
            primaryEntry.element.relationships = [];
          primaryEntry.element.relationships.push({
            id: sigmaShortId(),
            targetElementId: tgtEntry.element.id,
            keys,
            name: tgtName
          });
          warnings.push(`\u2139 Join ${primaryTableName} \u2192 ${tgtName} (${t.joinType || "left"}) on ${pairDesc.join(" AND ")}`);
        }
        joinTableIndex = { byTable: elementMap, primaryTableName };
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
        const metaRecords = asArray(rootConn?.["metadata-records"]?.["metadata-record"] || []);
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
          const path = extractPath(rel, dbEff, schEff, whCasing);
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
          let sqlText = "";
          if (isCustomSql) {
            const decoded = qualifyTwoPartFqns(unescapeCustomSqlEntities(String(rel["#text"] ?? "")).trim(), dbEff);
            const collapsed = collapseDoubledComparisonOps(decoded);
            sqlText = collapsed.sql;
            if (collapsed.rewrites > 0) {
              warnings.push(`\u26A0 Custom SQL relation "${fullName}": collapsed ${collapsed.rewrites} doubled comparison operator(s) (<<\u2192<, >>=\u2192>=) \u2014 a Tableau ObjectModel encapsulation artifact. VERIFY these are comparisons, not bit-shift operators.`);
            }
          }
          const source = isCustomSql && sqlText ? { connectionId: connId, kind: "sql", statement: sqlText } : { connectionId: connId, kind: "warehouse-table", path };
          if (isCustomSql && !sqlText) {
            warnings.push(`\u26A0 Custom SQL relation "${fullName}" has no inline SQL text \u2014 emitted as a table path "${path.join(".")}"; verify or replace with the query.`);
          }
          const el = { id: sigmaShortId(), kind: "table", source, columns, order };
          if (source.kind === "sql")
            el._sqlOrigin = "source-custom-sql";
          elementMap[fullName] = { element: el, colIdMap, cleanName, objId: relObjId };
          elements.push(el);
        }
        const objGraph = nsChild(ds.ds, "object-graph");
        const relsList = asArray(objGraph?.relationships?.relationship || []);
        // ---- role-played logical tables (one physical table, N instances) ----
        // Tableau serializes a role-played dim as N <relation> entries sharing
        // ONE physical `table` attr; the <object-graph> object carries the ROLE
        // caption ("Ship Date"). Capture the caption STRUCTURALLY (object ->
        // properties -> relation name), give each instance element a distinct
        // deterministic name and role-suffix its relationship name so every
        // [Base/REL/Field] ref resolves to its OWN instance — no FK-display or
        // table-name guessing downstream.
        const physByRelName = {};
        for (const rel of childRels) {
          const nm = attr(rel, "name") || attr(rel, "table") || "TABLE";
          physByRelName[nm] = String(attr(rel, "table") || "").toUpperCase();
        }
        const physInstanceCount = {};
        for (const nm of Object.keys(physByRelName)) {
          const p = physByRelName[nm];
          if (p)
            physInstanceCount[p] = (physInstanceCount[p] || 0) + 1;
        }
        for (const ob of asArray(objGraph?.objects?.object || [])) {
          const cap = String(attr(ob, "caption") || "").trim();
          if (!cap)
            continue;
          let obRelName = "";
          for (const p of asArray(nsChild(ob, "properties") || ob?.properties || [])) {
            const r = asArray(p?.relation || [])[0];
            if (r) {
              obRelName = attr(r, "name") || attr(r, "table") || "";
              if (obRelName)
                break;
            }
          }
          const entry = obRelName ? elementMap[obRelName] : void 0;
          if (!entry)
            continue;
          const phys = physByRelName[obRelName] || "";
          if (phys && physInstanceCount[phys] >= 2 && cap.toUpperCase() !== entry.cleanName.toUpperCase()) {
            entry.roleCaption = cap;
            if (!entry.element.name)
              entry.element.name = `${entry.cleanName} (${cap})`;
          }
        }
        const relCoverage = { serialized: relsList.length, wired: 0, entries: [] };
        const getCleanSeg = (name) => name.replace(/[\[\]]/g, "").split(".").pop()?.replace(/_[0-9A-Fa-f]{16,}$/, "").toUpperCase() || "";
        // Role instances of one physical table cannot be told apart by NAME: a
        // fallback (non-exact-objId) hit on any multi-instance table is
        // AMBIGUOUS — a silent first-match would glue every role's relationship
        // onto instance 0 (the role-collapse class). Refuse and report instead.
        const findEntry = (objId) => {
          const exactKey = Object.keys(elementMap).find((k) => elementMap[k].objId === objId);
          if (exactKey)
            return elementMap[exactKey];
          const cleanId = getCleanSeg(objId);
          const keys = Object.keys(elementMap).filter((k) => getCleanSeg(k) === cleanId);
          if (keys.length === 0)
            return void 0;
          const phys = physByRelName[keys[0]] || "";
          const instKeys = phys ? Object.keys(elementMap).filter((k) => physByRelName[k] === phys) : keys;
          if (keys.length > 1 || instKeys.length > 1)
            return { __roleAmbiguous: true, candidates: instKeys.length > 1 ? instKeys : keys };
          return elementMap[keys[0]];
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
        const hasCol = (entry, key) => !!(entry.colIdMap[key] || entry.colIdMap[key.replace(/-/g, "_")]);
        // --- object-graph relationship key derivation ladder (PR2a) ---
        // Tableau's 2020.2+ logical model AUTO-MATCHES relationships by column name at query
        // time and serializes NO join key at all \u2014 that is the modern-star-schema common case,
        // not an edge case. A purely-computed key (IF/DATETRUNC expression) is the other case
        // Sigma cannot join on directly. Both fall through to this conservative name-match
        // inference before being recorded as unwired, per docs/superpowers/plans/2026-07-30-pr2a-spike.md:
        // never fabricate a column via ensureCol for a guessed name (only call it once existence
        // is confirmed on both sides via colIdMap), and never combine multiple name matches into
        // a composite key \u2014 an incidental second match (e.g. both sides carrying CREATED_AT)
        // would over-constrain the join and silently drop rows. A single key-shaped candidate is
        // wired; anything else (none, or more than one) is left for manual authoring.
        const candidateNameIndex = (entry) => {
          const byName = /* @__PURE__ */ new Map();
          for (const c of entry.element.columns || []) {
            const raw = c.name || (typeof c.formula === "string" && (c.formula.match(/\/([^\]]+)\]$/) || [])[1]);
            if (!raw)
              continue;
            const normalized = String(raw).replace(/\s+/g, "_").toUpperCase();
            if (!byName.has(normalized))
              byName.set(normalized, /* @__PURE__ */ new Set());
            byName.get(normalized).add(c.id || c.formula || raw);
          }
          return byName;
        };
        const entityNameOf = (cleanName) => String(cleanName || "").toUpperCase().replace(/^(DIM|FACT|BRIDGE)_/, "");
        const escapeRe = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        // Precise, NOT `includes`: a loose substring match on the entity name wires
        // non-key denormalized columns (a fact's CUSTOMER_NAME shares "CUSTOMER" with
        // DIM_CUSTOMER and would otherwise become the sole "candidate", getting wired
        // on a name column a dim is usually unique on — gate 16's probe cannot catch
        // that) AND discards genuine keys (ORDER_DATE contains "DATE", so a DIM_DATE
        // pair sharing both DATE_KEY and ORDER_DATE would see 2 "key-shaped" candidates
        // and refuse to wire the obvious DATE_KEY). A name is key-shaped only if it ends
        // in an explicit key suffix (entity-agnostic — two unrelated *_ID columns
        // shared between two tables correctly yields 2 candidates and no guess), IS the
        // target entity name exactly, or is the target entity name plus a key suffix.
        const isKeyShapedName = (name, entityName) => /_(ID|KEY|SK|CODE)$/.test(name) || !!entityName && (name === entityName || new RegExp(`^${escapeRe(entityName)}_(ID|KEY|SK|CODE)$`).test(name));
        // Deny-list (unique-on-right NON-keys): EXTERNAL_ID / ROW_ID / GUID /
        // HASH_KEY families are key-shaped by suffix and frequently unique on
        // the right side, but they are lineage/tech columns, not the
        // relationship key - and gate 16's warehouse probe proves UNIQUENESS,
        // not CORRECTNESS, so a wired one silently returns wrong rows. Denied
        // from INFERENCE candidacy only: a key Tableau explicitly serialized
        // is still honored, and a denied-only match is recorded unwired with
        // a named reason. Side effect by design: a denied name no longer
        // manufactures false ambiguity beside a genuine key.
        const INFERENCE_KEY_DENYLIST_RE = /(^|_)(EXTERNAL_ID|ROW_ID|GUID|HASH_KEY)$/;
        const inferRelationshipKeyByName = (firstEntry, secondEntry) => {
          const leftIndex = candidateNameIndex(firstEntry);
          const rightIndex = candidateNameIndex(secondEntry);
          const leftNames = Array.from(leftIndex.keys());
          const rightSet = new Set(rightIndex.keys());
          const seen = /* @__PURE__ */ new Set();
          const candidates = [];
          for (const n of leftNames) {
            if (seen.has(n))
              continue;
            seen.add(n);
            if (rightSet.has(n) && hasCol(firstEntry, n) && hasCol(secondEntry, n))
              candidates.push(n);
          }
          const entityName = entityNameOf(secondEntry.cleanName);
          const keyShapedAll = candidates.filter((n) => isKeyShapedName(n, entityName));
          const denied = keyShapedAll.filter((n) => INFERENCE_KEY_DENYLIST_RE.test(n));
          const keyShaped = keyShapedAll.filter((n) => !INFERENCE_KEY_DENYLIST_RE.test(n));
          const collisions = keyShaped.filter((n) => leftIndex.get(n).size > 1 || rightIndex.get(n).size > 1);
          if (keyShaped.length === 1 && collisions.length === 0)
            return { ok: true, name: keyShaped[0], candidates, keyShaped, denied, collisions };
          return { ok: false, candidates, keyShaped, denied, collisions };
        };
        const unwiredReason = (inferred) => (inferred.collisions || []).length ? `ambiguous normalized column name collision (${inferred.collisions.join(", ")}) - more than one real column on an endpoint maps to the same inference key; refusing to select whichever colIdMap entry won last` : inferred.candidates.length === 0 ? "no existing column name matches on both sides" : inferred.keyShaped.length === 0 ? (inferred.denied || []).length ? `only deny-listed non-key name(s) matched (${inferred.denied.join(", ")}) - EXTERNAL_ID/ROW_ID/GUID/HASH_KEY-family columns are lineage/tech columns a probe can prove unique but never correct; author the relationship manually if one truly is the key` : "candidate name(s) matched but none look key-shaped (a _ID/_KEY/_SK/_CODE suffix, the exact target entity name, or the entity name plus that suffix)" : `ambiguous: ${inferred.keyShaped.length} key-shaped candidates \u2014 refusing to guess a composite key`;
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
        // Non-equality comparison clauses (range / inequality relationships,
        // official operators per Tableau "Relate Your Data"): collectEqs walks
        // PAST them silently, so census them separately \u2014 a rel whose only
        // clauses are ranges must land in the named-gap path, not vanish.
        const collectNonEq = (expr, acc) => {
          const op = nsAttr(expr, "op");
          if (["<", "<=", ">", ">=", "!=", "<>"].includes(String(op).trim()))
            acc.push(op);
          for (const k of asArray(expr.expression || []))
            collectNonEq(k, acc);
        };
        const isPhysical = (op) => /^\[[^\]]+\]$/.test(op.trim());
        // PASS 1 \u2014 collect every wire-able edge WITHOUT attaching it. Tableau
        // serializes the already-on-canvas (base) table as first-end-point and
        // the base is pure authoring order (docs: "the first table that you
        // drag"), so endpoint order carries NO fact semantics. Attachment is
        // decided after election, in pass 2.
        // Composition with the PR2a ladder: the ladder decides WHICH keys
        // wire (serialized -> name-inference -> unwired-and-recorded); the
        // object-model passes decide HOW edges attach (fact election,
        // orientation, role-played instancing).
        const relEdges = [];
        const unwiredRels = [];
        for (const rel of relsList) {
          const firstEp = rel["first-end-point"];
          const secondEp = rel["second-end-point"];
          const firstObjId = firstEp ? attr(firstEp, "object-id") : "";
          const secondObjId = secondEp ? attr(secondEp, "object-id") : "";
          if (!firstEp || !secondEp) {
            relCoverage.entries.push({
              left: firstObjId || "(missing first-end-point)",
              right: secondObjId || "(missing second-end-point)",
              derivedVia: "unwired",
              reason: "relationship XML is missing a first-end-point or second-end-point"
            });
            continue;
          }
          const firstEntry = findEntry(firstObjId);
          const secondEntry = findEntry(secondObjId);
          if (firstEntry?.__roleAmbiguous || secondEntry?.__roleAmbiguous) {
            // Refuse-don't-guess: the end-point matches SEVERAL instances of one
            // role-played physical table and nothing identifies which role owns
            // this relationship \u2014 first-match wiring here is exactly the silent
            // role collapse (two roles keyed onto one element).
            const amb = firstEntry?.__roleAmbiguous ? firstEntry : secondEntry;
            const ambId = firstEntry?.__roleAmbiguous ? attr(firstEp, "object-id") : attr(secondEp, "object-id");
            warnings.push(`\u26A0 Relationship end-point object-id "${ambId}" matches ${amb.candidates.length} role-played instances (${amb.candidates.map((c) => `"${c}"`).join(", ")}) and none exactly \u2014 role attribution AMBIGUOUS; NOT wired. Wire manually: one element instance per role, one relationship on that role's own key.`);
            unwiredRels.push({ a: firstEntry?.cleanName || attr(firstEp, "object-id"), b: secondEntry?.cleanName || attr(secondEp, "object-id"), why: "role-ambiguous" });
            relCoverage.entries.push({
              left: firstEntry?.cleanName || firstObjId || "(unresolved)",
              right: secondEntry?.cleanName || secondObjId || "(unresolved)",
              derivedVia: "unwired",
              reason: `end-point object-id "${ambId}" matches ${amb.candidates.length} role-played instances and none exactly \u2014 role attribution ambiguous`,
              candidates: amb.candidates
            });
            continue;
          }
          if (!firstEntry || !secondEntry || firstEntry === secondEntry) {
            const missing = [!firstEntry ? attr(firstEp, "object-id") : null, !secondEntry ? attr(secondEp, "object-id") : null].filter(Boolean).join('", "');
            warnings.push(`\u26A0 Relationship end-point object-id "${missing}" matches no logical table (renamed object / unsupported shape) \u2014 NOT wired; wire this relationship manually (LEFT from fact\u2192dim).`);
            unwiredRels.push({ a: firstEntry?.cleanName || attr(firstEp, "object-id"), b: secondEntry?.cleanName || attr(secondEp, "object-id"), why: "endpoint-unresolved" });
            relCoverage.entries.push({
              left: firstEntry ? firstEntry.cleanName : firstObjId || "(unresolved)",
              right: secondEntry ? secondEntry.cleanName : secondObjId || "(unresolved)",
              derivedVia: "unwired",
              reason: !firstEntry || !secondEntry ? `endpoint object-id unresolved to a known element (first=${firstObjId || "?"}, second=${secondObjId || "?"})` : "both endpoints resolve to the same element"
            });
            continue;
          }
          const eqExprs = [];
          const nonEqOps = [];
          for (const oe of asArray(rel.expression || [])) {
            collectEqs(oe, eqExprs);
            collectNonEq(oe, nonEqOps);
          }
          const wireInferred = (name, { droppedConditions = 0 } = {}) => {
            // Ladder x object-model composition: an inferred key joins the
            // edge set like a serialized one \u2014 attachment/orientation is
            // decided in pass 2 after fact election, so derivedVia and the
            // dropped-condition census ride on the edge.
            const inferredKeys = [{
              aColId: ensureCol(firstEntry, name),
              bColId: ensureCol(secondEntry, name)
            }];
            relEdges.push({
              a: firstEntry,
              b: secondEntry,
              keys: inferredKeys,
              uniqueA: /^true$/i.test(String(attr(firstEp, "unique-key") || "")),
              uniqueB: /^true$/i.test(String(attr(secondEp, "unique-key") || "")),
              dbUniqueA: /^true$/i.test(String(attr(firstEp, "is-db-set-unique-key") || "")),
              dbUniqueB: /^true$/i.test(String(attr(secondEp, "is-db-set-unique-key") || "")),
              relExprText: JSON.stringify(rel.expression || ""),
              derivedVia: "name-inference",
              ...droppedConditions > 0 ? { droppedConditions } : {}
            });
            relCoverage.wired += 1;
            relCoverage.entries.push({
              left: firstEntry.cleanName,
              right: secondEntry.cleanName,
              derivedVia: "name-inference",
              keyCount: inferredKeys.length,
              ...droppedConditions > 0 ? { partial: true, droppedConditions } : {}
            });
          };
          const recordUnwired = (inferred) => {
            relCoverage.entries.push({
              left: firstEntry.cleanName,
              right: secondEntry.cleanName,
              derivedVia: "unwired",
              reason: unwiredReason(inferred),
              candidates: inferred.candidates,
              ...inferred.collisions && inferred.collisions.length > 0 ? { collisions: inferred.collisions } : {}
            });
          };
          if (eqExprs.length === 0) {
            if (nonEqOps.length === 0) {
              // No serialized key at all: run the PR2a name-inference rung
              // before recording the gap.
              const inferred = inferRelationshipKeyByName(firstEntry, secondEntry);
              if (inferred.ok) {
                wireInferred(inferred.name);
                warnings.push(`\u2139 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName}: no serialized join key (Tableau auto-matches these at query time) \u2014 inferred "${inferred.name}" from a column name that exists on both sides. VERIFY this is the correct key before relying on it.`);
                continue;
              }
              warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName} carries no serialized join key \u2014 Tableau auto-matches these at query time; Sigma needs an explicit key. NOT wired: pick a join key and wire manually (LEFT from fact\u2192dim), and verify the dimension is unique on the key to avoid measure fan-out.`);
              unwiredRels.push({ a: firstEntry.cleanName, b: secondEntry.cleanName, why: "no-serialized-key" });
              recordUnwired(inferred);
            } else {
              // Range/inequality relationship: NEVER equality-inferred \u2014 an
              // '=' join where Tableau declared a range predicate is a wrong
              // join, not a recovered one. Refuse and record.
              warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName} joins only on non-equality operator(s) (${nonEqOps.join(", ")}) \u2014 a range/inequality relationship has no Sigma relationship equivalent (relationships join on column equality). NOT wired: model as a join element or wire manually.`);
              unwiredRels.push({ a: firstEntry.cleanName, b: secondEntry.cleanName, why: "non-equality-key" });
              relCoverage.entries.push({
                left: firstEntry.cleanName,
                right: secondEntry.cleanName,
                derivedVia: "unwired",
                reason: `joins only on non-equality operator(s) (${nonEqOps.join(", ")}) \u2014 a range/inequality relationship has no Sigma relationship equivalent`
              });
            }
            continue;
          }
          const keys = [];
          let skippedComputed = 0;
          for (const eq of eqExprs) {
            const inner = asArray(eq.expression || []);
            if (inner.length < 2)
              continue;
            let srcOpRaw = nsAttr(inner[0], "op") || "";
            let tgtOpRaw = nsAttr(inner[1], "op") || "";
            if (!isPhysical(srcOpRaw) || !isPhysical(tgtOpRaw)) {
              // DATE()/DATETIME()-wrapped side (role-played date joins): when
              // the wrapped column resolves on one of THIS relationship's own
              // end-point entries, synthesize a deterministic calc key column
              // (Date([Col])) on that side and wire the equality on it — the
              // role's key stays on its own instance. Unknown functions and
              // unresolvable wrapped columns keep the refuse path (computed-only
              // named gap), never a guess.
              const fnKeySigma = { DATE: "Date", DATETIME: "Date" };
              const fnWrapOf = (raw) => {
                const m = String(raw).trim().match(/^([A-Za-z_]+)\(\[?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]?\)$/i);
                return m && fnKeySigma[m[1].toUpperCase()] ? { fn: fnKeySigma[m[1].toUpperCase()], raw: m[1].toUpperCase(), uuid: m[2].toUpperCase() } : null;
              };
              const ensureCalcKey = (entry, wrap) => {
                const baseId = entry.colIdMap[wrap.uuid] || entry.colIdMap[wrap.uuid.replace(/-/g, "_")];
                if (!baseId)
                  return "";
                const baseCol = entry.element.columns.find((c) => c.id === baseId);
                const bm = baseCol && String(baseCol.formula || "").match(/^\[[^/\]]+\/([^\]]+)\]$/);
                const baseDisp = baseCol && baseCol.name || bm && bm[1] || "";
                if (!baseDisp || baseDisp.includes("/"))
                  return "";
                const calcMapKey = `${wrap.uuid}::${wrap.fn}KEY`;
                let calcId = entry.colIdMap[calcMapKey];
                if (!calcId) {
                  calcId = sigmaInodeId(wrap.uuid.replace(/-/g, "_") + "_KEY");
                  entry.element.columns.push({ id: calcId, name: `${baseDisp} Join Key`, formula: `${wrap.fn}([${baseDisp}])` });
                  entry.element.order.push(calcId);
                  entry.colIdMap[calcMapKey] = calcId;
                  warnings.push(`ℹ Relationship ${firstEntry.cleanName} → ${secondEntry.cleanName}: computed key ${wrap.raw}([${baseDisp}]) wired via synthesized calc key column "${baseDisp} Join Key".`);
                }
                return calcId;
              };
              const srcWrap = fnWrapOf(srcOpRaw);
              const tgtWrap = fnWrapOf(tgtOpRaw);
              let aId = "", bId = "";
              if (srcWrap && !tgtWrap && isPhysical(tgtOpRaw)) {
                aId = ensureCalcKey(firstEntry, srcWrap);
                if (aId)
                  bId = ensureCol(secondEntry, parseOpRef(tgtOpRaw));
              } else if (tgtWrap && !srcWrap && isPhysical(srcOpRaw)) {
                bId = ensureCalcKey(secondEntry, tgtWrap);
                if (bId)
                  aId = ensureCol(firstEntry, parseOpRef(srcOpRaw));
              }
              if (aId && bId) {
                keys.push({ aColId: aId, bColId: bId });
                continue;
              }
              skippedComputed++;
              continue;
            }
            let srcKey = parseOpRef(srcOpRaw), tgtKey = parseOpRef(tgtOpRaw);
            if (!srcKey || !tgtKey)
              continue;
            // Operand order parallels end-point order by CONVENTION only \u2014 the
            // format does not specify side-ownership. Verify by column ownership
            // and swap when both operands resolve exclusively on the opposite
            // side; genuinely ambiguous stays serialized-order.
            if (!hasCol(firstEntry, srcKey) && !hasCol(secondEntry, tgtKey) && hasCol(secondEntry, srcKey) && hasCol(firstEntry, tgtKey)) {
              const t = srcKey;
              srcKey = tgtKey;
              tgtKey = t;
              warnings.push(`\u2139 Relationship ${firstEntry.cleanName} \u2194 ${secondEntry.cleanName}: operand order did not match end-point order \u2014 swapped by column ownership.`);
            }
            keys.push({ aColId: ensureCol(firstEntry, srcKey), bColId: ensureCol(secondEntry, tgtKey) });
          }
          if (keys.length === 0) {
            const inferred = inferRelationshipKeyByName(firstEntry, secondEntry);
            if (inferred.ok) {
              wireInferred(inferred.name, { droppedConditions: skippedComputed });
              warnings.push(`\u2139 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName}: joins only on computed key(s) with no physical column to wire \u2014 inferred "${inferred.name}" from a column name that exists on both sides instead. VERIFY this is the correct key before relying on it.`);
              if (skippedComputed > 0) {
                warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName}: name-inference wired "${inferred.name}", but ${skippedComputed} computed condition(s) Tableau also required (e.g. IF/DATETRUNC expression) could not be carried into the join \u2014 this join is WIDER than Tableau's (it will match rows Tableau's computed condition would have excluded). Verify join grain in Sigma.`);
              }
              continue;
            }
            warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName} joins only on computed key(s) (e.g. IF/DATETRUNC expression); Sigma joins on physical columns only \u2014 NOT wired. Needs a computed join column or manual authoring.`);
            unwiredRels.push({ a: firstEntry.cleanName, b: secondEntry.cleanName, why: "computed-only-key" });
            recordUnwired(inferred);
            continue;
          }
          if (skippedComputed > 0) {
            warnings.push(`\u26A0 Relationship ${firstEntry.cleanName} \u2192 ${secondEntry.cleanName}: wired ${keys.length} physical key(s); ${skippedComputed} computed condition(s) dropped \u2014 verify join grain in Sigma.`);
          }
          relEdges.push({
            a: firstEntry,
            b: secondEntry,
            keys,
            uniqueA: /^true$/i.test(String(attr(firstEp, "unique-key") || "")),
            uniqueB: /^true$/i.test(String(attr(secondEp, "unique-key") || "")),
            dbUniqueA: /^true$/i.test(String(attr(firstEp, "is-db-set-unique-key") || "")),
            dbUniqueB: /^true$/i.test(String(attr(secondEp, "is-db-set-unique-key") || "")),
            relExprText: JSON.stringify(rel.expression || ""),
            derivedVia: "serialized",
            ...skippedComputed > 0 ? { droppedConditions: skippedComputed } : {}
          });
          relCoverage.wired += 1;
          relCoverage.entries.push({
            left: firstEntry.cleanName,
            right: secondEntry.cleanName,
            derivedVia: "serialized",
            keyCount: keys.length,
            ...skippedComputed > 0 ? { partial: true, droppedConditions: skippedComputed } : {}
          });
        }
        // ---- evidence-ranked fact election (replaces first-in-document-order).
        // Rank: relationship degree \u2192 measure-column count (numeric, non-key)
        // \u2192 not-dim-like name \u2192 widest \u2192 warehouse row count when supplied
        // (options.tableRowCounts). options.factTable overrides outright.
        const entryList = Object.keys(elementMap).map((k) => elementMap[k]);
        let electedEntry = null;
        if (entryList.length > 1) {
          const degree = /* @__PURE__ */ new Map();
          const keyColIds = /* @__PURE__ */ new Set();
          for (const e of relEdges) {
            degree.set(e.a, (degree.get(e.a) || 0) + 1);
            degree.set(e.b, (degree.get(e.b) || 0) + 1);
            for (const k of e.keys) {
              keyColIds.add(k.aColId);
              keyColIds.add(k.bColId);
            }
          }
          const dimLikeName = (n) => /(^|[\s_])(?:vw?_?)?dim/i.test(String(n || ""));
          const measureCount = (entry) => {
            let n = 0;
            for (const c of entry.element.columns || []) {
              const t = colTypeById[c.id];
              if ((t === "integer" || t === "real") && !keyColIds.has(c.id))
                n++;
            }
            return n;
          };
          const rowsOf = (entry) => {
            if (!tableRowCounts)
              return null;
            const p = entry.element.source?.path || [];
            for (const k of [p.join("."), p[p.length - 1], entry.cleanName]) {
              if (!k)
                continue;
              if (tableRowCounts[k] != null)
                return Number(tableRowCounts[k]);
              if (tableRowCounts[String(k).toUpperCase()] != null)
                return Number(tableRowCounts[String(k).toUpperCase()]);
            }
            return null;
          };
          const scoreOf = (entry) => [degree.get(entry) || 0, measureCount(entry), dimLikeName(entry.cleanName) ? 0 : 1, (entry.element.columns || []).length, rowsOf(entry) ?? -1];
          if (factTable) {
            const want = String(factTable).toUpperCase();
            electedEntry = entryList.find((en) => en.cleanName.toUpperCase() === want || (en.element.source?.path || [])[en.element.source?.path?.length - 1]?.toUpperCase?.() === want) || null;
            if (electedEntry) {
              warnings.push(`\u2139 Object-model fact election: "${electedEntry.cleanName}" set by factTable override.`);
            } else {
              warnings.push(`\u26A0 factTable override "${factTable}" matches no logical table \u2014 falling back to evidence-ranked election.`);
            }
          }
          if (!electedEntry) {
            const scores = entryList.map((en) => ({ en, s: scoreOf(en) }));
            const cmp = (x, y) => {
              for (let i = 0; i < x.length; i++) {
                if (x[i] !== y[i])
                  return x[i] > y[i] ? 1 : -1;
              }
              return 0;
            };
            let best = scores[0];
            for (const cand of scores.slice(1)) {
              if (cmp(cand.s, best.s) > 0)
                best = cand;
            }
            const tiedWith = scores.filter((c) => c !== best && cmp(c.s, best.s) === 0).map((c) => c.en.cleanName);
            electedEntry = best.en;
            const bs = best.s;
            const rowsNote = bs[4] >= 0 ? `, rows ${bs[4]}` : "";
            warnings.push(`\u2139 Object-model fact election: elected "${electedEntry.cleanName}" as the fact/base element (relationships ${bs[0]}, measure columns ${bs[1]}, ${bs[3]} column(s)${rowsNote}). Every LOD/Top-N/window helper builds its SQL FROM this element \u2014 if this is wrong, re-run with the factTable option (--fact-table) or re-point and re-validate the DM.`);
            if (tiedWith.length > 0) {
              warnings.push(`\u26A0 Fact election AMBIGUOUS \u2014 "${electedEntry.cleanName}" ties with ${tiedWith.map((n) => `"${n}"`).join(", ")} on every signal (relationships, measure columns, naming, width). Elected by document order; VERIFY, and pass factTable to override.`);
            }
          }
        }
        // PASS 2 \u2014 orient every collected edge off the elected fact: Sigma
        // relationships are directional (source = the more granular / many
        // side), so the carrier is the endpoint NEARER the fact \u2014 dims become
        // targets and snowflake chains nest (fact reaches sub-dims through
        // inherited relationships).
        if (relEdges.length > 0) {
          const adj = /* @__PURE__ */ new Map();
          for (const e of relEdges) {
            if (!adj.has(e.a))
              adj.set(e.a, []);
            if (!adj.has(e.b))
              adj.set(e.b, []);
            adj.get(e.a).push(e);
            adj.get(e.b).push(e);
          }
          const dist = /* @__PURE__ */ new Map();
          const visitOrder = /* @__PURE__ */ new Map();
          let visitSeq = 0;
          const bfs = (root) => {
            if (dist.has(root))
              return;
            dist.set(root, 0);
            visitOrder.set(root, visitSeq++);
            const q = [root];
            while (q.length) {
              const cur = q.shift();
              for (const e of adj.get(cur) || []) {
                const other = e.a === cur ? e.b : e.a;
                if (!dist.has(other)) {
                  dist.set(other, dist.get(cur) + 1);
                  visitOrder.set(other, visitSeq++);
                  q.push(other);
                }
              }
            }
          };
          if (electedEntry && adj.has(electedEntry))
            bfs(electedEntry);
          for (const en of entryList) {
            if (adj.has(en) && !dist.has(en)) {
              const hub = [...adj.keys()].filter((x) => !dist.has(x)).sort((x, y) => (adj.get(y)?.length || 0) - (adj.get(x)?.length || 0))[0];
              if (electedEntry && hub !== electedEntry) {
                warnings.push(`\u26A0 Object-model: a second relationship tree is NOT connected to the elected fact "${electedEntry.cleanName}" (multi-fact / disconnected forest) \u2014 rooted its edges at "${hub.cleanName}"; VERIFY, and wire the forests together (or split the model) before trusting cross-tree results.`);
              }
              bfs(hub);
            }
          }
          const hintContradicted = [];
          for (const e of relEdges) {
            const da = dist.get(e.a) ?? 0;
            const db = dist.get(e.b) ?? 0;
            let carrier = e.a, target = e.b, carrierUnique = e.uniqueA, targetUnique = e.uniqueB;
            let keys = e.keys.map((k) => ({ sourceColumnId: k.aColId, targetColumnId: k.bColId }));
            // Sigma relationships are many -> one lookups. Tableau serializes
            // decisive endpoint cardinality as unique-key=true together with
            // is-db-set-unique-key=true; when exactly one endpoint has that
            // database-backed evidence, it MUST be the target even
            // when the relationship-degree election picked the unique hub as
            // the workbook's default/fact element. Ignoring this evidence
            // produces a valid-looking one -> many Lookup that returns one
            // arbitrary child row and silently undercounts child-fact measures.
            // Both/neither unique remains on the evidence-ranked BFS path.
            const uniqueHintDecisive = e.dbUniqueA !== e.dbUniqueB;
            const flip = uniqueHintDecisive ? e.dbUniqueA : db < da || db === da && (visitOrder.get(e.b) ?? 0) < (visitOrder.get(e.a) ?? 0);
            if (flip) {
              carrier = e.b;
              target = e.a;
              carrierUnique = e.uniqueB;
              targetUnique = e.uniqueA;
              keys = e.keys.map((k) => ({ sourceColumnId: k.bColId, targetColumnId: k.aColId }));
            }
            if (carrierUnique && !targetUnique)
              hintContradicted.push(`${carrier.cleanName}\u2192${target.cleanName}`);
            if (!carrier.element.relationships)
              carrier.element.relationships = [];
            carrier.element.relationships.push({
              id: sigmaShortId(),
              targetElementId: target.element.id,
              keys,
              // Role-played instances get role-suffixed relationship names so
              // every [Base/REL/Field] ref resolves to its OWN instance.
              name: target.roleCaption ? `${target.cleanName} (${target.roleCaption})` : target.cleanName,
              // PR2a provenance survives orientation: how the key was derived
              // (serialized | name-inference) rides on every attached edge.
              derivedVia: e.derivedVia || "serialized",
              ...e.droppedConditions > 0 ? { partial: true, droppedConditions: e.droppedConditions } : {}
            });
            warnings.push(`\u2139 Relationship ${carrier.cleanName} \u2192 ${target.cleanName} wired on ${keys.length} ${e.derivedVia === "name-inference" ? "name-inferred" : "physical"} key(s).`);
          }
          if (hintContradicted.length > 0) {
            warnings.push(`\u26A0 Tableau performance-option hints (unique-key) mark the SOURCE side unique on ${hintContradicted.length} oriented edge(s): ${hintContradicted.join(", ")}. As oriented these would be one-to-many, which a Sigma relationship cannot express (many-to-one left join into a unique target) \u2014 the hints are often db-derived or stale, so VERIFY each edge's direction and target uniqueness; model a genuinely one-to-many edge as a join element instead.`);
          }
        }
        electedFactEl = electedEntry ? electedEntry.element : null;
        relationshipCoverage = relCoverage;
        const joinableEls = elements.filter((e) => e.source?.kind === "warehouse-table" || e.source?.kind === "sql");
        const wiredRelCount = elements.reduce((n, e) => n + (e.relationships?.length || 0), 0);
        if (joinableEls.length > 1 && wiredRelCount === 0) {
          warnings.push(relsList.length === 0 ? `\u26A0 Tableau logical (relationship / noun) datasource: ${joinableEls.length} tables but NO relationships were serialized in <object-graph> \u2014 nothing to derive a join key from (Tableau matches these at query time). The DM is a set of disconnected tables. Pick an explicit join key for each table pair and wire relationships manually (LEFT from fact\u2192dim), and verify each dimension is unique on the key to avoid measure fan-out.` : `\u26A0 Tableau logical (relationship / noun) datasource: ${joinableEls.length} tables and ${relsList.length} relationship(s), but 0 could be wired \u2014 all lacked a physical equality key (auto-matched or computed-only; see per-relationship warnings above). The DM is a set of disconnected tables. Pick an explicit join key per pair and wire manually (LEFT from fact\u2192dim); verify dimension uniqueness on the key.`);
        }
        // Refuse-don't-guess: every relationship that could NOT be wired is a
        // NAMED gap (structured, machine-readable), not just a drive-by WARN \u2014
        // and a partial wire (some edges up, some down) gets its own summary so
        // \u22651 wired can never read as all-clear.
        for (const u of unwiredRels) {
          workbookPatterns.push({
            kind: "unsupported",
            name: `Object-model relationship ${u.a} \u2194 ${u.b} (${u.why})`,
            source: `<object-graph> relationship ${u.a} \u2194 ${u.b}`,
            requires: "MANUAL relationship wiring in the Sigma data model: pick the join key column pair, add the relationship LEFT from the many (fact) side to the unique (dim) side, and verify dimension uniqueness on the key.",
            note: `The serialized relationship carried no usable physical equality key (${u.why}). Until wired, this table pair is DISCONNECTED in the DM \u2014 cross-table results involving it are wrong or unavailable.`
          });
        }
        if (unwiredRels.length > 0 && wiredRelCount > 0) {
          warnings.push(`\u26A0 Object-model: ${wiredRelCount} of ${relsList.length} relationship(s) wired; ${unwiredRels.length} NOT wired (${unwiredRels.map((u) => `${u.a}\u2194${u.b}: ${u.why}`).join("; ")}). The unwired pairs are DISCONNECTED tables \u2014 wire them manually (LEFT from fact\u2192dim) before trusting cross-table results. Each is reported as a named gap in result.workbookPatterns.`);
        }
        if (relEdges.length > 0) {
          const touched = /* @__PURE__ */ new Set();
          for (const e of relEdges) {
            touched.add(e.a);
            touched.add(e.b);
          }
          const isolated = entryList.filter((en) => !touched.has(en) && (en.element.source?.kind === "warehouse-table" || en.element.source?.kind === "sql"));
          for (const iso of isolated) {
            warnings.push(`\u26A0 Object-model: logical table "${iso.cleanName}" has NO wired relationship to any other table \u2014 it is DISCONNECTED in the DM. Wire it manually (LEFT from fact\u2192dim) or drop it.`);
            workbookPatterns.push({
              kind: "unsupported",
              name: `Object-model table ${iso.cleanName} disconnected`,
              source: `<object-graph> logical table ${iso.cleanName}`,
              requires: "MANUAL relationship wiring (or removal) of the isolated logical table.",
              note: "No serialized relationship reaches this table \u2014 it is disconnected in the emitted DM."
            });
          }
          objectModelInfo = { entries: entryList, edges: relEdges, elected: electedEntry };
        } else if (entryList.length > 1) {
          objectModelInfo = { entries: entryList, edges: [], elected: electedEntry };
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
        if (!dbEff || !schEff) {
          warnings.push("\u26A0 Virtual connection: pass database and schema parameters to set the full warehouse path.");
        }
      }
    } else if (relType === "text") {
      const _collapsed = collapseDoubledComparisonOps(unescapeCustomSqlEntities((rootRelation["#text"] || "").toString()).trim());
      if (_collapsed.rewrites > 0) {
        warnings.push(`\u26A0 Custom SQL datasource: collapsed ${_collapsed.rewrites} doubled comparison operator(s) (<<\u2192<, >>=\u2192>=) \u2014 a Tableau ObjectModel encapsulation artifact. VERIFY these are comparisons, not bit-shift operators.`);
      }
      const statement = _repointCustomSqlSchema(_collapsed.sql, attr(rootConn, "dbname"), attr(rootConn, "schema"), dbEff, schEff);
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
          for (const mr of asArray(rootConn?.["metadata-records"]?.["metadata-record"] || [])) {
            if (attr(mr, "class") !== "column")
              continue;
            const remote = (mr["remote-name"] || "").trim();
            if (remote)
              rawCols.push({ name: remote });
          }
        }
        const columns = [], order = [];
        const seen = /* @__PURE__ */ new Set();
        const projParts = [];
        let needsRealias = false;
        for (const rc of rawCols) {
          const clean = rc.name.replace(/^\[|\]$/g, "");
          const upper = clean.toUpperCase();
          if (!clean || seen.has(upper))
            continue;
          seen.add(upper);
          const colKey = clean.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
          const colRefRaw = clean === colKey ? colKey : clean;
          const colRef = colRefRaw.replace(/\//g, "-");
          const display = capByName[upper] || sigmaDisplayName(clean);
          const id = sigmaInodeId(colRef);
          columns.push({ id, formula: `[Custom SQL/${colRef}]`, name: display });
          order.push(id);
          if (colRef !== colRefRaw) {
            projParts.push(`"${clean}" AS "${colRef}"`);
            needsRealias = true;
          } else if (colRefRaw === colKey) {
            projParts.push(colRefRaw);
          } else {
            projParts.push(`"${clean}"`);
          }
        }
        const finalStatement = needsRealias ? `SELECT ${projParts.join(", ")} FROM (
${statement}
) __cs` : statement;
        elements.push({
          id: sigmaShortId(),
          kind: "table",
          source: { connectionId: connId, kind: "sql", statement: finalStatement },
          columns,
          order,
          _sqlOrigin: "source-custom-sql"
        });
        if (columns.length === 0) {
          warnings.push("\u26A0 Custom SQL element emitted with no columns (no <columns> projection or column metadata-records found) \u2014 add columns from the query output.");
        } else {
          warnings.push(`\u2139 Custom SQL datasource \u2192 Sigma SQL element (source.kind:'sql', ${columns.length} column(s)). The SQL statement is preserved verbatim; verify column display names resolve against the query output.`);
        }
      }
    } else if (relType === "union") {
      // W2.16: Tableau union datasource. Emits the documented Sigma union
      // source (kind:"union" + sources + matches) for the dominant
      // same-connection wildcard-union shape; anything underivable falls to a
      // LOUD named refusal \u2014 a unioned datasource previously converted to
      // NOTHING, silently (the worst defect class under the program's rules).
      // Shape per sigma-data-models reference/sources.md "Union" (live-verified):
      //   - sources are elementId-based (direct warehouse-table entries fail on
      //     special-char columns) \u2192 one intermediate warehouse-table element
      //     per union member;
      //   - the union element carries NO name (an explicit name breaks
      //     self-referential column validation; the API auto-names it
      //     "Union of N Sources") \u2192 its column formulas use that prefix;
      //   - sourceColumns entries are bracketed friendly column names resolved
      //     within each member element's own column set.
      const allUnionKids = asArray(rootRelation.relation || []);
      const unionChildren = allUnionKids.filter((r) => (attr(r, "type") || "table") === "table");
      // W2.16 fix-pass: members that are NOT plain tables (custom-SQL text,
      // nested union, join) used to be dropped by the filter above and the
      // union emitted from the table members alone — a silent SUBSET (the
      // missing members' rows vanished with no refusal). Any non-table member
      // now refuses the whole union loudly instead.
      const nonTableKids = allUnionKids.filter((r) => (attr(r, "type") || "table") !== "table");
      const unionName = ((attr(rootRelation, "name") || ds.name || "Union").replace(/[\[\]]/g, "")) || "Union";
      const srcPaths = unionChildren.map((r) => extractPath(r, dbEff, schEff, whCasing)).filter((pp) => pp && pp.length > 0);
      const capByName = {};
      for (const col of asArray(ds.ds?.column || [])) {
        const nm = (attr(col, "name") || "").replace(/^\[|\]$/g, "");
        const cap = attr(col, "caption");
        if (nm && cap)
          capByName[nm.toUpperCase()] = cap;
      }
      const outCols = [];
      const seenUnionCols = /* @__PURE__ */ new Set();
      for (const mr of asArray(rootConn?.["metadata-records"]?.["metadata-record"] || [])) {
        if (attr(mr, "class") !== "column")
          continue;
        const remote = (mr["remote-name"] || "").trim();
        if (!remote || seenUnionCols.has(remote.toUpperCase()))
          continue;
        if (/^(Sheet|Table Name)$/i.test(remote))
          continue; // Tableau union-provenance bookkeeping columns, not warehouse columns
        seenUnionCols.add(remote.toUpperCase());
        outCols.push(remote);
      }
      if (nonTableKids.length > 0) {
        const kidDesc = nonTableKids.map((r) => `${attr(r, "name") || "(unnamed)"}: type '${attr(r, "type")}'`).join("; ");
        warnings.push(`\u26a0 Union datasource "${unionName}" NOT converted \u2014 ${nonTableKids.length} of ${allUnionKids.length} union member(s) are not plain tables (${kidDesc}); emitting the ${unionChildren.length} table member(s) alone would silently drop the other member(s)' rows. NO ELEMENTS EMITTED for this datasource \u2014 model it as a Custom SQL UNION ALL element, or re-point sources after conversion.`);
      } else if (srcPaths.length >= 2 && outCols.length > 0) {
        // Members FIRST (displayNameMap is last-writer-wins, so the union
        // element \u2014 built last \u2014 owns every column's resolution), union
        // element LAST; factEl selection prefers a union source so translated
        // calcs and auto-metrics attach to the stacked rows, not one member.
        const memberSources = [];
        for (const pp of srcPaths) {
          const memberTable = pp[pp.length - 1] || "MEMBER";
          const mCols = [], mOrder = [];
          for (const c of outCols) {
            const mid = sigmaInodeId(c.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase());
            mCols.push({ id: mid, formula: `[${memberTable}/${sigmaDisplayName(c)}]`, name: sigmaDisplayName(c) });
            mOrder.push(mid);
          }
          const mEl = {
            id: sigmaShortId(),
            kind: "table",
            source: { connectionId: connId, kind: "warehouse-table", path: pp },
            columns: mCols,
            order: mOrder
          };
          elements.push(mEl);
          memberSources.push({ kind: "table", elementId: mEl.id });
        }
        const unionPrefix = `Union of ${srcPaths.length} Sources`;
        const matches = outCols.map((c) => ({ outputColumnName: sigmaDisplayName(c), sourceColumns: srcPaths.map(() => `[${sigmaDisplayName(c)}]`) }));
        const columns = [], order = [];
        for (const c of outCols) {
          const id = sigmaInodeId(c.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase());
          columns.push({ id, formula: `[${unionPrefix}/${sigmaDisplayName(c)}]`, name: capByName[c.toUpperCase()] || sigmaDisplayName(c) });
          order.push(id);
        }
        elements.push({
          id: sigmaShortId(),
          kind: "table",
          source: { kind: "union", sources: memberSources, matches },
          columns,
          order
        });
        warnings.push(`\u26a0 Union datasource "${unionName}" \u2192 Sigma union source (${srcPaths.length} member element(s) + 1 union element, ${outCols.length} column(s)), assuming SAME-NAME columns across members (wildcard union). Sigma auto-names the union element "${unionPrefix}" \u2014 rename in the UI if desired (setting a spec name breaks self-referential column validation). VERIFY: a member with renamed/missing columns needs hand-edited matches (null for a member lacking the column).`);
      } else {
        warnings.push(`\u26a0 Union datasource "${unionName}" NOT converted \u2014 ${srcPaths.length} derivable member table(s), ${outCols.length} derivable output column(s); emitting a Sigma union source (kind:"union" + sources + matches) needs \u22652 members and \u22651 column. NO ELEMENTS EMITTED for this datasource \u2014 model it as a Custom SQL UNION ALL element, or re-point sources after conversion.`);
      }
    } else {
      warnings.push(`\u26a0 Datasource root relation type "${relType}" is not supported by the converter \u2014 NO ELEMENTS EMITTED for this datasource. Supported: table, join, collection, text (Custom SQL), union.`);
    }
  }
  // Fact resolution: the evidence-ranked object-model election wins when it
  // ran (and its element survived blend collapse); otherwise keep the legacy
  // fallback chain for non-noodle shapes — first relationship carrier, then
  // union element (W2.16: calcs/metrics attach to the stacked rows), then widest.
  const factEl = electedFactEl && elements.includes(electedFactEl) ? electedFactEl : elements.find((e) => e.relationships?.length > 0) || elements.find((e) => e.source?.kind === "union") || (elements.length > 0 ? elements.reduce((best, e) => (e.columns?.length || 0) > (best.columns?.length || 0) ? e : best, elements[0]) : null);
  if (factEl) {
    let _baseFromExpr2 = function() {
      const fe = factEl;
      if (fe?.source?.kind === "sql" && fe.source.statement) {
        const stmt = fe.source.statement;
        const upperStmt = stmt.trimStart();
        if (/^WITH\s/i.test(upperStmt)) {
          const firstTopSelectIdx = firstTopLevelSelectIndex(stmt);
          if (firstTopSelectIdx > 0) {
            const ctePart = stmt.slice(0, firstTopSelectIdx).replace(/^\s*WITH\s+/i, "").replace(/,?\s*$/, "");
            const selectPart = stmt.slice(firstTopSelectIdx);
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
      return { dimUpper: physicalUpper, displayName: dispName, baseColId: found.colId, onFact: found.el === factEl, el: found.el };
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
        order: helperOrder,
        _sqlOrigin: "generated-lod"
      };
      lodHelpers[signatureKey] = {
        element: helperEl,
        // Use the RESOLVED physical-upper names (aligned 1:1 with effectiveDims),
        // not the raw effective names. INCLUDE/EXCLUDE worksheet dims arrive as
        // display strings (e.g. "SALES REGION" with a space); the resolved
        // dimUpper ("SALES_REGION") is what quotePhysToken maps to the real
        // quoted warehouse column and what keeps GROUP BY / SELECT consistent.
        groupDimNames: dimResolved.map((d) => d.dimUpper),
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
      const factColIds = new Set((factEl.columns || []).map((c) => c.id));
      for (let i = 0; i < dimResolved.length; i++) {
        const baseColId = dimResolved[i].baseColId;
        const helperColId = rec.groupDimColIds[i];
        if (!baseColId || !helperColId)
          return;
        // Ownership guard: a relationship's sourceColumnId MUST be a column of
        // the carrying (fact) element — a related-table column id here is the
        // spec-invalid shape that POSTs as "Dependency not found".
        if (!factColIds.has(baseColId)) {
          warnings.push(`⚠ Helper relationship "${relName}" skipped: grouping column [${dimResolved[i].displayName}] does not live on the fact element — a cross-element relationship key is spec-invalid. Author the helper join manually (grouped Custom SQL fact→dim).`);
          return;
        }
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
    }, _suggestCrossTableLodSql2 = function(lod, dimsResolved, caption) {
      const fe = factEl;
      if (fe?.source?.kind !== "warehouse-table" || !(fe.source.path?.length >= 1))
        return null;
      const physNameOf = (el, colId) => {
        const c = (el?.columns || []).find((x) => x.id === colId);
        if (!c)
          return null;
        const nm = c.name || typeof c.formula === "string" && (c.formula.match(/\/([^\]]+)\]$/) || [])[1];
        return nm ? String(nm).replace(/\s+/g, "_").toUpperCase() : null;
      };
      const qFact = (u) => physToRealQuoted[u] || u;
      const factPath = fe.source.path.join(".");
      const factPhys = new Set((fe.columns || []).map((c) => physNameOf(fe, c.id)).filter(Boolean));
      const joins = [];
      const joinByEl = /* @__PURE__ */ new Map();
      const dimSel = [];
      for (const d of dimsResolved) {
        if (!d.el || d.el === fe) {
          dimSel.push(`__f.${qFact(d.dimUpper)} AS ${_qidIfNeeded(d.dimUpper)}`);
          continue;
        }
        const dimEl = d.el;
        if (dimEl.source?.kind !== "warehouse-table" || !(dimEl.source.path?.length >= 1))
          return null;
        const rel = (fe.relationships || []).find((r) => r.targetElementId === dimEl.id);
        if (!rel || !rel.keys?.length)
          return null;
        let alias = joinByEl.get(dimEl.id);
        if (!alias) {
          alias = `__d${joins.length}`;
          const on = [];
          for (const k of rel.keys) {
            const fp = physNameOf(fe, k.sourceColumnId), dp = physNameOf(dimEl, k.targetColumnId);
            if (!fp || !dp)
              return null;
            on.push(`__f.${qFact(fp)} = ${alias}.${dp}`);
          }
          joins.push({ alias, path: dimEl.source.path.join("."), on });
          joinByEl.set(dimEl.id, alias);
        }
        dimSel.push(`${alias}.${d.dimUpper} AS ${_qidIfNeeded(d.dimUpper)}`);
      }
      if (joins.length === 0)
        return null;
      const aggExpr = String(lod.aggExpr || "").replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b/g, (m, tok) => factPhys.has(tok.toUpperCase()) ? `__f.${qFact(tok.toUpperCase())}` : m);
      const aggAlias = (caption || "LOD_VALUE").replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").toUpperCase() || "LOD_VALUE";
      const aggFn = lod.aggFunc === "COUNTD" ? `COUNT(DISTINCT ${aggExpr})` : `${lod.aggFunc}(${aggExpr})`;
      const gb = dimSel.map((_s, i) => i + 1).join(", ");
      const joinSql = joins.map((j) => `    LEFT JOIN ${j.path} ${j.alias} ON ${j.on.join(" AND ")}`).join("\n");
      return `    SELECT ${dimSel.join(", ")}, ${aggFn} AS ${aggAlias}
    FROM ${factPath} __f
${joinSql}
    GROUP BY ${gb}`;
    }, _finalizeHelpers2 = function() {
      const { fromClause, ctePrefix } = _baseFromExpr2();
      const useBase = fromClause === "__lod_base";
      for (const sigKey of Object.keys(lodHelpers)) {
        const rec = lodHelpers[sigKey];
        const dimList = useBase ? rec.groupDimDisplayNames.map((dn) => physToQuotedAlias[dn.replace(/\s+/g, "_").toUpperCase()] || _qid(dn)).join(", ") : rec.groupDimNames.map((dn) => {
          const q = sqlExactByUpper[dn.toUpperCase()] || quotePhysToken(dn);
          return q === dn ? dn : `${q} AS ${_qidIfNeeded(dn)}`;
        }).join(", ");
        const aggParts = [];
        for (const k of Object.keys(rec.aggsByExpr)) {
          const a = rec.aggsByExpr[k];
          const safeExpr = useBase ? rewriteBaseExpr(a.aggExpr) : rewriteSqlExactExpr(rewritePhysExpr(a.aggExpr));
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
      // Ownership guard (refuse-don't-guess): the helper's SQL builds FROM the
      // fact and its surfacing relationship is keyed on the fact \u2014 an off-fact
      // ranking/partition column would bake a wrong-FROM SELECT and a
      // cross-element relationship key ("Dependency not found" at POST).
      if (keyResolved.onFact === false) {
        warnings.push(`\u26A0 Set "${top.caption}": ranking key [${top.dimField}] lives on related element "${keyResolved.el?.name || (keyResolved.el?.source?.path || []).slice(-1)[0] || "?"}", not the fact \u2014 a single-table Top-N helper would SELECT it FROM the wrong table. Skipped: author the Top-N as a grouped Custom SQL element joining fact\u2192dim on the relationship key, then relate it back to the fact.`);
        return false;
      }
      const partResolved = [];
      for (const p of top.partitionBy) {
        const r = _resolveDimDisplayName2(p);
        if (!r || !r.baseColId) {
          warnings.push(`\u26A0 Set "${top.caption}": partition dim [${p}] not found on base; skipped.`);
          return false;
        }
        if (r.onFact === false) {
          warnings.push(`\u26A0 Set "${top.caption}": partition dim [${p}] lives on related element "${r.el?.name || (r.el?.source?.path || []).slice(-1)[0] || "?"}", not the fact \u2014 refusing a wrong-FROM helper. Author as grouped Custom SQL joining fact\u2192dim.`);
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
        const cidBase = sanitizeControlId(sigmaDisplayName(ctlSourceName));
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
      const groupDims = [keyResolved.dimUpper, ...partResolved.map((p) => p.dimUpper)];
      const _tnSource = (c) => {
        if (topNUseBase)
          return physToQuotedAlias[c] || c;
        const q = quotePhysToken(c);
        return q === c ? c : `${q} AS ${c}`;
      };
      const _tnOut = (c) => topNUseBase ? physToQuotedAlias[c] || c : c;
      const groupColsSource = groupDims.map(_tnSource);
      const groupColsOut = groupDims.map(_tnOut);
      const groupByIdx = groupDims.map((_g, i) => i + 1).join(", ");
      let aggSql = top.byAggFunc;
      const safeByField = topNUseBase ? rewriteBaseExpr(top.byField) : rewritePhysExpr(top.byField);
      if (aggSql === "COUNTD")
        aggSql = `COUNT(DISTINCT ${safeByField})`;
      else
        aggSql = `${aggSql}(${safeByField})`;
      const partBy = top.partitionBy.length > 0 ? `PARTITION BY ${top.partitionBy.map(_tnOut).join(", ")} ` : "";
      const overClause = `RANK() OVER (${partBy}ORDER BY s ${dirSql})`;
      const innerSelect = `SELECT ${groupColsSource.join(", ")}, ${aggSql} AS s FROM ${topNFrom} GROUP BY ${groupByIdx}`;
      const rankedSelect = `SELECT ${groupColsOut.join(", ")}, s, ${overClause} AS RNK FROM agg`;
      const outerCols = emitIsTopNInSql ? `${groupColsOut.join(", ")}, s AS TOTAL, RNK, (RNK <= ${nLiteral}) AS IS_TOP_N` : `${groupColsOut.join(", ")}, s AS TOTAL, RNK`;
      const outerSelect = `SELECT ${outerCols} FROM ranked`;
      const statement = topNCtePrefix ? `WITH ${topNCtePrefix}agg AS (${innerSelect}), ranked AS (${rankedSelect}) ${outerSelect}` : `WITH agg AS (${innerSelect}), ranked AS (${rankedSelect}) ${outerSelect}`;
      const helperEl = {
        id: helperId,
        kind: "table",
        // No element-level name field for kind:sql elements (per spec rule 3).
        source: { connectionId: connId, kind: "sql", statement },
        columns: cols,
        order,
        _sqlOrigin: "generated-top-n"
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
        order,
        _sqlOrigin: "generated-window"
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
      const _factColIds = new Set((factEl.columns || []).map((c) => c.id));
      const partitionsOnFact = partitionDims.every((d) => d.baseColId && _factColIds.has(d.baseColId));
      if (!alreadyLinked && partitionDims.length > 0 && partitionDims.every((d) => d.baseColId) && !partitionsOnFact) {
        // Ownership guard: a partition dim resolved to a RELATED element's
        // column would put a cross-element key on the fact relationship
        // (spec-invalid, "Dependency not found" at POST). Keep the helper,
        // skip the surfacing relationship, and say so.
        warnings.push(`⚠ Window helper "${relName}": partition dim(s) live on a related element, not the fact — surfacing relationship skipped (cross-element keys are spec-invalid). Relate the helper manually or re-author as grouped Custom SQL joining fact→dim.`);
      }
      if (!alreadyLinked && partitionDims.length > 0 && partitionsOnFact) {
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
      const _winUseBase = _baseFromExpr2().fromClause === "__lod_base";
      const _emitPartDim = (d) => _winUseBase ? physToQuotedAlias[d] || _qidIfNeeded(d) : _qidIfNeeded(d);
      const partBy = rec.partitionDimNames.length > 0 ? `PARTITION BY ${rec.partitionDimNames.map(_emitPartDim).join(", ")}` : "";
      const orderBy = rec.orderDimAlias ? `ORDER BY ${_qidIfNeeded(rec.orderDimAlias)}` : "";
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
        const emitPartSource = (d) => {
          if (winUseBase)
            return physToQuotedAlias[d] || _qidIfNeeded(d);
          const q = quotePhysToken(d);
          return q === d ? d : `${q} AS ${_qidIfNeeded(d)}`;
        };
        for (const d of rec.partitionDimNames) {
          selectParts.push(emitPartSource(d));
        }
        if (rec.orderDimRaw && rec.orderDimAlias) {
          const rawRef = winUseBase ? rewriteBaseExpr(rec.orderDimRaw) : rewritePhysExpr(rec.orderDimRaw);
          if (rec.orderDimDateTrunc) {
            selectParts.push(`DATE_TRUNC('${rec.orderDimDateTrunc}', ${rawRef}) AS ${_qidIfNeeded(rec.orderDimAlias)}`);
          } else {
            selectParts.push(`${rawRef} AS ${_qidIfNeeded(rec.orderDimAlias)}`);
          }
        }
        for (const k of Object.keys(rec.innerAggs)) {
          const [aggFunc, exprSql] = k.split("::");
          const safeExpr = winUseBase ? rewriteBaseExpr(exprSql) : rewritePhysExpr(exprSql);
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
          ...rec.partitionDimNames.map((d) => _qidIfNeeded(d)),
          ...rec.orderDimAlias ? [_qidIfNeeded(rec.orderDimAlias)] : [],
          ...Object.values(rec.innerAggs).map((v) => v.alias)
        ];
        const outerProjection = innerProjection.concat(rec.windowOverParts);
        rec.element.source.statement = winCtePrefix ? `WITH ${winCtePrefix}base AS (${baseSelect}) SELECT ${outerProjection.join(", ")} FROM base` : `WITH base AS (${baseSelect}) SELECT ${outerProjection.join(", ")} FROM base`;
      }
    };
    var _baseFromExpr = _baseFromExpr2, _resolveDimDisplayName = _resolveDimDisplayName2, _ensureHelper = _ensureHelper2, _ensureRelationship = _ensureRelationship2, _addAggToHelper = _addAggToHelper2, _suggestCrossTableLodSql = _suggestCrossTableLodSql2, _finalizeHelpers = _finalizeHelpers2, _emitTopNHelper = _emitTopNHelper2, _ensureWindowHelper = _ensureWindowHelper2, _registerInnerAgg = _registerInnerAgg2, _emitWindowOverClause = _emitWindowOverClause2, _finalizeWindowHelpers = _finalizeWindowHelpers2;
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
    // ---- structural RLS detection: datasource filters + entitlement tables.
    // Doctrine (owner veto): the checkpoint fires on the DOCUMENTED STRUCTURAL
    // SHAPE — a related/joined table carrying a user-identity column plus a
    // user-function datasource filter (or a datasource filter / user-function
    // relationship term tied to that table). A name regex (/RLS|ENTITLE/) may
    // only color the report TEXT (low-confidence hint) — it never fires, and
    // never suppresses, detection on its own. Datasource <filter> elements
    // were previously NEVER scanned: a formula-regex over calc columns alone
    // is blind to Tableau's documented entitlement-table best practice.
    {
      const _calcNodeOf = (col) => Array.isArray(col.calculation) ? col.calculation[0] : col.calculation;
      const calcFormulaByName = {};
      for (const col of asArray(ds.ds?.column || [])) {
        const nm = (attr(col, "name") || "").replace(/^\[|\]$/g, "");
        const calcNode = _calcNodeOf(col);
        const f = calcNode ? nsAttr(calcNode, "formula") : "";
        if (nm && f)
          calcFormulaByName[nm.toUpperCase()] = String(f);
      }
      const dsFilters = asArray(ds.ds?.filter || []).map((f) => {
        const rawCol = String(attr(f, "column") || "");
        const groups = [...rawCol.matchAll(/\[([^\]]+)\]/g)].map((m) => m[1]);
        let colName = groups.length ? groups[groups.length - 1] : rawCol;
        colName = colName.replace(/^[a-z]+:/i, "").replace(/:(nk|qk|ok)$/i, "");
        return {
          klass: String(attr(f, "class") || ""),
          colName,
          exprRaw: String(nsAttr(f, "expression") || ""),
          calcF: calcFormulaByName[colName.toUpperCase()] || ""
        };
      });
      const ownerOf = (colName) => {
        const key = String(colName || "").toUpperCase();
        const found = displayNameMap[key] || displayNameMap[key.replace(/\s+/g, "_")] || displayNameMap[sigmaDisplayName(String(colName || "")).toUpperCase()];
        return found ? found.el : null;
      };
      // (a) datasource filters carrying a user function — fact-local shape.
      // A filter hosted on a CALC column is left to the calc-column pass
      // below (which already emits fact-local rules) to avoid double-emits;
      // this covers the pure `<filter class='expression'>` form.
      for (const f of dsFilters) {
        const formulaSrc = f.exprRaw || f.calcF;
        if (!formulaSrc || !tableauFormulaIsRls(formulaSrc))
          continue;
        const refs = [...formulaSrc.matchAll(/\[([^\]]+)\]/g)].map((m) => m[1]);
        const offFactOwner = refs.map((r) => ownerOf(r)).find((el) => el && el !== factEl);
        if (offFactOwner)
          continue;
        if (f.calcF)
          continue;
        const sigmaFormula = tableauFormulaToSigma(formulaSrc, warnings);
        if (sigmaFormula && !sigmaFormula.startsWith("/*")) {
          security.push(makeRlsSecurity({ source: `Tableau datasource filter${f.colName ? ` on [${f.colName}]` : ""}`, element: factEl, name: "RLS: datasource filter", formula: sigmaFormula }));
          warnings.push(`🔐 Datasource filter carries a user function → row-level security DETECTED (reported in result.security, not injected): ${sigmaFormula.slice(0, 80)}`);
        } else {
          security.push({
            kind: "rls",
            source: "Tableau datasource filter (untranslated)",
            elementId: factEl.id,
            elementName: _securityElementName(factEl),
            rls: { name: "RLS: datasource filter", formula: `/* verify: ${formulaSrc.slice(0, 120)} */` },
            note: "User-function datasource filter did not auto-translate — re-author fail-closed in Sigma (boolean calc + element filter keeping only True)."
          });
          warnings.push(`🔐 Datasource filter carries a user function (${formulaSrc.slice(0, 60)}) that did not fully translate — RLS reported in result.security for manual re-authoring (CurrentUserEmail()/CurrentUserAttributeText/CurrentUserInTeam); NOT silently dropped.`);
        }
      }
      // (b) entitlement-table shape over the object-model graph.
      if (objectModelInfo && objectModelInfo.entries.length > 1) {
        const om = objectModelInfo;
        const identityColRe = /^(?:user[\s_-]?)?e[\s_-]?mail(?:[\s_-]?address)?$|^user(?:[\s_-]?(?:name|id|login|key|principal[\s_-]?name))?$|^login$|^upn$/i;
        for (const en of om.entries) {
          if (en.element === factEl)
            continue;
          const edge = om.edges.find((e) => e.a === en || e.b === en);
          if (!edge)
            continue;
          let identityCol = null, identityVia = null;
          for (const f of dsFilters) {
            const src = [f.exprRaw, f.calcF].filter(Boolean).join(" ");
            if (!src || !tableauFormulaIsRls(src))
              continue;
            for (const rm of src.matchAll(/\[([^\]]+)\]/g)) {
              if (ownerOf(rm[1]) === en.element) {
                identityCol = rm[1];
                identityVia = "a user-function datasource filter references it";
                break;
              }
            }
            if (identityCol)
              break;
          }
          if (!identityCol && edge.relExprText && tableauFormulaIsRls(edge.relExprText)) {
            identityCol = "(see relationship expression)";
            identityVia = "a user-function term inside the relationship expression";
          }
          if (!identityCol) {
            const filterTiedToEntry = dsFilters.some((f) => f.colName && ownerOf(f.colName) === en.element);
            if (filterTiedToEntry) {
              for (const c of en.element.columns || []) {
                const disp = c.name || (typeof c.formula === "string" && (c.formula.match(/\/([^\]]+)\]$/) || [])[1]) || "";
                if (identityColRe.test(String(disp).trim())) {
                  identityCol = String(disp);
                  identityVia = "an identity-shaped column plus a datasource filter on this table";
                  break;
                }
              }
            }
          }
          if (!identityCol)
            continue;
          const otherEntry = edge.a === en ? edge.b : edge.a;
          const colNameOf = (el, id) => {
            const c = (el.columns || []).find((x) => x.id === id);
            return c ? c.name || (typeof c.formula === "string" && (c.formula.match(/\/([^\]]+)\]$/) || [])[1]) || c.id : "?";
          };
          const keys = edge.keys.map((k) => en === edge.a ? { entitlementColumn: colNameOf(edge.a.element, k.aColId), relatedColumn: colNameOf(edge.b.element, k.bColId) } : { entitlementColumn: colNameOf(edge.b.element, k.bColId), relatedColumn: colNameOf(edge.a.element, k.aColId) });
          const nameHint = /(rls|entitle|securit)/i.test(en.cleanName) ? " (table name also reads entitlement-like — low-confidence hint only)" : "";
          security.push({
            kind: "rls-entitlement-table",
            source: `object-model related table "${en.cleanName}" — ${identityVia}`,
            elementId: en.element.id,
            elementName: en.cleanName,
            entitlement: {
              identityColumn: identityCol,
              relatedElementName: otherEntry.cleanName,
              factElementName: _securityElementName(factEl) || factTableName,
              keys,
              strategies: [
                "A (materialized gate): fail-closed filter on the entitlement element ([identity] = CurrentUserEmail() + include-True list filter), then INNER-JOIN the fact to the filtered element (join-source element). Probe (identity, key) uniqueness first — a non-unique pair fans out fact rows.",
                "B (row-preserving gate): on the entitlement element add [Is Me] = ([identity] = CurrentUserEmail()); on the fact add Lookup(Sum(If([Is Me], 1, 0)), [key], [key]) > 0 with an include-True filter. Null-safe fail-closed; no fan-out by construction.",
                "C (de-entitle): map entitlements onto Sigma user attributes (single-valued only — refuse multi-valued) or teams (group-shaped) and use the documented CurrentUserAttributeText / CurrentUserInTeam filter."
              ]
            },
            note: "Table-based entitlement RLS detected STRUCTURALLY (related table + user-identity column + datasource-filter/user-function signal). NEVER auto-applied — until the RLS checkpoint decision the wired relationship is an UNCONSTRAINED live join: the Tableau restriction is gone and multi-entitlement users fan out row counts. Decide Port (A/B), Customize, or loud Skip (refs/security-rls.md)."
          });
          warnings.push(`🔐 Entitlement-table RLS pattern DETECTED: "${en.cleanName}" (identity column [${identityCol}]; ${identityVia})${nameHint} — reported in result.security as kind "rls-entitlement-table"; NOT applied. Until the RLS checkpoint decision the ${en.cleanName} relationship is an UNCONSTRAINED live join (restriction dropped + fan-out risk).`);
        }
      }
    }
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
    const physToRealQuoted = {};
    if (factEl?.source?.kind !== "sql") {
      const _addReal = (remote) => {
        const r = (remote || "").trim();
        if (!r)
          return;
        const snakeUpper = r.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
        const normUpper = r.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_|_$/g, "").toUpperCase();
        const spaceUpper = r.replace(/\s+/g, "_").toUpperCase();
        if (r === snakeUpper && !/^[0-9]/.test(r))
          return;
        const quoted = `"${r}"`;
        for (const k of [snakeUpper, normUpper, spaceUpper]) {
          if (k && !(k in physToRealQuoted))
            physToRealQuoted[k] = quoted;
        }
      };
      for (const mr of asArray(rootConn?.["metadata-records"]?.["metadata-record"] || [])) {
        _addReal(mr["remote-name"] || "");
      }
    }
    const hasRealNames = Object.keys(physToRealQuoted).length > 0;
    const quotePhysToken = (tok) => physToRealQuoted[tok] || physToRealQuoted[tok.toUpperCase()] || tok;
    const rewritePhysExpr = (expr) => !hasRealNames ? expr : expr.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b/g, (m, tok) => physToRealQuoted[tok.toUpperCase()] || m);
    const sqlExactByUpper = {};
    if (factEl?.source?.kind === "sql") {
      for (const col of factEl?.columns || []) {
        const fm = typeof col.formula === "string" && col.formula.match(/\/([^\]]+)\]$/);
        const exact = fm ? fm[1] : col.name || "";
        if (!exact)
          continue;
        const upper = exact.replace(/[^A-Za-z0-9_]/g, "_").toUpperCase();
        if (exact === upper)
          continue;
        sqlExactByUpper[upper] = `"${exact}"`;
      }
    }
    const hasSqlExact = Object.keys(sqlExactByUpper).length > 0;
    const rewriteSqlExactExpr = (expr) => !hasSqlExact ? expr : expr.replace(/\b([A-Za-z_][A-Za-z0-9_]*)\b/g, (m, tok) => sqlExactByUpper[tok.toUpperCase()] || m);
    const lodChildElements = [];
    const wsIndex = _buildWorksheetIndex(parsed);
    // Sigma accepts a metric whose name equals a sibling column, but live
    // readback then drops the element's entire metric collection (F4). Raw
    // numeric measures already exist as columns, so their convenience Sum()
    // metrics must use a distinct, deterministic display name.
    const _autoMetricName = (displayName) => {
      const occupied = new Set([
        ...(factEl.columns || []).map((c) => String(c.name || "").toLowerCase()),
        ...(factEl.metrics || []).map((m) => String(m.name || "").toLowerCase())
      ]);
      const base = `Total ${displayName}`;
      let candidate = base;
      let suffix = 2;
      while (occupied.has(candidate.toLowerCase()))
        candidate = `${base} (${suffix++})`;
      return candidate;
    };
    const lodHelpers = {};
    const usedAliases = /* @__PURE__ */ new Set();
    const topNHelpers = [];
    const topNUsedAliases = /* @__PURE__ */ new Set();
    const topNSetIndex = {};
    const windowWsIndex = _buildWindowWorksheetIndex(parsed);
    const windowHelpers = {};
    const windowUsedAliases = /* @__PURE__ */ new Set();
    const windowChildElements = [];
    const _jcNorm = (s) => String(s || "").toUpperCase().replace(/[^0-9A-Z]/g, "");
    const _jcColDisplay = (c) => c.name || typeof c.formula === "string" && (c.formula.match(/\/([^\]]+)\]$/) || [])[1] || "";
    let _jcIndex = null;
    const _jcBuildIndex = () => {
      const out = [];
      for (const tn of Object.keys(joinTableIndex.byTable)) {
        const el = joinTableIndex.byTable[tn].element;
        const byNorm = {}, dup = {};
        for (const c of el.columns || []) {
          const disp = _jcColDisplay(c);
          if (!disp)
            continue;
          const k = _jcNorm(disp);
          if (byNorm[k] && byNorm[k] !== disp)
            dup[k] = true;
          else
            byNorm[k] = disp;
        }
        out.push({ tableName: tn, el, byNorm, dup });
      }
      return out;
    };
    const _jcElName = (entry) => {
      if (!entry.el.name)
        entry.el.name = sigmaDisplayName(entry.tableName);
      return entry.el.name;
    };
    const _jcTryOn = (entry, name) => {
      const k = _jcNorm(name);
      if (!k || entry.dup[k])
        return null;
      const disp = entry.byNorm[k];
      return disp ? { entry, display: disp } : null;
    };
    const _jcResolveRef = (token) => {
      const m = token.match(/^(.*?)\s*\(([^()]+)\)\s*$/);
      if (m) {
        const want = _jcNorm(m[2].replace(/_[0-9A-Fa-f]{16,}$/, ""));
        const entry = _jcIndex.find((e) => _jcNorm(e.tableName.replace(/_[0-9A-Fa-f]{16,}$/, "")) === want);
        if (entry) {
          const hit = _jcTryOn(entry, m[1]);
          if (hit)
            return hit;
        }
      }
      const primary = _jcIndex.find((e) => e.el === factEl);
      if (primary) {
        const hit = _jcTryOn(primary, token);
        if (hit)
          return hit;
      }
      const hits = [];
      for (const e of _jcIndex) {
        if (e.el === factEl)
          continue;
        const h = _jcTryOn(e, token);
        if (h)
          hits.push(h);
      }
      return hits.length === 1 ? hits[0] : null;
    };
    const _jcCompositeKeys = {};
    const _jcLookupArg = (res) => {
      const rel = (factEl.relationships || []).find((r) => r.targetElementId === res.entry.el.id);
      if (!rel || !(rel.keys || []).length)
        return null;
      const tgt = _jcElName(res.entry);
      const dispOf = (el, colId) => {
        const c = (el.columns || []).find((x) => x.id === colId);
        return c ? _jcColDisplay(c) || null : null;
      };
      let localKeyRef, remoteKeyRef;
      if (rel.keys.length === 1) {
        const lk = dispOf(factEl, rel.keys[0].sourceColumnId);
        const rk = dispOf(res.entry.el, rel.keys[0].targetColumnId);
        if (!lk || !rk)
          return null;
        localKeyRef = `[${lk}]`;
        remoteKeyRef = `[${tgt}/${rk}]`;
      } else {
        let synth = _jcCompositeKeys[rel.id];
        if (!synth) {
          const localParts = [], remoteParts = [];
          for (const k of rel.keys) {
            const lk = dispOf(factEl, k.sourceColumnId);
            const rk = dispOf(res.entry.el, k.targetColumnId);
            if (!lk || !rk)
              return null;
            localParts.push(`Text([${lk}])`);
            remoteParts.push(`Text([${rk}])`);
          }
          const keyName = `${sigmaDisplayName(res.entry.tableName)} Join Key`;
          const lid = sigmaShortId();
          factEl.columns.push({ id: lid, name: keyName, formula: localParts.join(' & "|" & ') });
          factEl.order.push(lid);
          const rid = sigmaShortId();
          res.entry.el.columns.push({ id: rid, name: keyName, formula: remoteParts.join(' & "|" & ') });
          res.entry.el.order.push(rid);
          synth = _jcCompositeKeys[rel.id] = { keyName };
          warnings.push(`\u2139 Synthesized composite join key "${keyName}" on both elements (${rel.keys.length}-key join; Sigma Lookup takes one key pair).`);
        }
        localKeyRef = `[${synth.keyName}]`;
        remoteKeyRef = `[${tgt}/${synth.keyName}]`;
      }
      return `Lookup([${tgt}/${res.display}], ${localKeyRef}, ${remoteKeyRef})`;
    };
    const _jcSplitTop = (s) => {
      const parts = [];
      let depth = 0, cur = "", inBr = false;
      for (const ch of s) {
        if (inBr) {
          cur += ch;
          if (ch === "]")
            inBr = false;
          continue;
        }
        if (ch === "[") {
          inBr = true;
          cur += ch;
          continue;
        }
        if (ch === "(")
          depth++;
        else if (ch === ")")
          depth--;
        if (ch === "," && depth === 0) {
          parts.push(cur);
          cur = "";
          continue;
        }
        cur += ch;
      }
      parts.push(cur);
      return parts;
    };
    const _jcChain = (fRaw) => {
      const f = String(fRaw || "").trim();
      let m = f.match(/^IFNULL\s*\((.*)\)$/is);
      if (m) {
        const parts = _jcSplitTop(m[1]);
        if (parts.length !== 2)
          return null;
        const a = _jcChain(parts[0]);
        const b = _jcChain(parts[1]);
        return a && b ? a.concat(b) : null;
      }
      m = f.match(/^ZN\s*\((.*)\)$/is);
      if (m) {
        const inner = _jcChain(m[1]);
        return inner ? inner.concat([{ lit: "0" }]) : null;
      }
      m = f.match(/^IF\s+ISNULL\s*\(\s*\[([^\]]+)\]\s*\)\s*THEN\s*\[([^\]]+)\]\s*ELSE\s*\[([^\]]+)\]\s*(?:END)?$/i);
      if (m && m[1] === m[3])
        return [{ ref: m[1] }, { ref: m[2] }];
      m = f.match(/^\[([^\]]+)\]$/);
      if (m)
        return [{ ref: m[1] }];
      return null;
    };
    const _tryJoinCoalesce = (caption, formula) => {
      if (!joinTableIndex)
        return false;
      const chain = _jcChain(formula);
      if (!chain || !chain.some((it) => it.ref))
        return false;
      if (!_jcIndex)
        _jcIndex = _jcBuildIndex();
      const isChain = chain.length >= 2;
      const args = [];
      for (const it of chain) {
        if (it.lit) {
          args.push(it.lit);
          continue;
        }
        const res = _jcResolveRef(it.ref);
        if (!res) {
          if (isChain)
            warnings.push(`\u26A0 "${caption}": cross-table coalesce over the federated join could not be auto-wired ([${it.ref}] did not resolve uniquely to a joined table's column) \u2014 falling back to the generic translator; expect a Lookup() hand-fix (refs/data-model-spec.md "Denormalizing dim columns").`);
          return false;
        }
        if (res.entry.el === factEl) {
          args.push(`[${res.display}]`);
        } else {
          const lookup = _jcLookupArg(res);
          if (!lookup) {
            warnings.push(`\u26A0 "${caption}": cross-table coalesce over the federated join could not be auto-wired (no usable relationship key from ${factTableName} to ${res.entry.tableName}) \u2014 falling back to the generic translator; expect a Lookup() hand-fix (refs/data-model-spec.md "Denormalizing dim columns").`);
            return false;
          }
          args.push(lookup);
        }
      }
      const sigmaFormula = args.length === 1 ? args[0] : `Coalesce(${args.join(", ")})`;
      const colId = sigmaShortId();
      const _fmt = inferSigmaFormat(sigmaFormula, caption);
      const _col = { id: colId, formula: sigmaFormula, name: caption };
      if (_fmt)
        _col.format = _fmt;
      factEl.columns.push(_col);
      factEl.order.push(colId);
      displayNameMap[caption.toUpperCase()] = { colId, el: factEl };
      displayNameMap[caption.replace(/\s+/g, "_").toUpperCase()] = { colId, el: factEl };
      globalColMap[caption.toUpperCase()] = { elId: factEl.id, displayName: caption };
      warnings.push(`\u2705 "${caption}": federated-join coalesce \u2192 ${sigmaFormula.slice(0, 140)}`);
      return true;
    };
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
        const _role = attr(col, "role") || "";
        const _dataType = attr(col, "datatype") || "";
        const _isNumericMeasure = _role === "measure" && (_dataType === "real" || _dataType === "integer" || _dataType === "decimal");
        const _tracked = displayNameMap[displayName.toUpperCase()] || displayNameMap[physCol];
        if (_tracked) {
          if (_isNumericMeasure) {
            if (!factEl.metrics)
              factEl.metrics = [];
            const _mets = factEl.metrics;
            if (_tracked.el === factEl) {
              const _sumFormula = `Sum([${displayName}])`;
              if (!_mets.some((m) => String(m.formula || "").toLowerCase() === _sumFormula.toLowerCase())) {
                const _fmt = inferSigmaFormat(`Sum([${displayName}])`, displayName);
                const _met = { id: sigmaShortId(), formula: _sumFormula, name: _autoMetricName(displayName) };
                if (_fmt)
                  _met.format = _fmt;
                _mets.push(_met);
              }
            } else if (!warnings.some((w) => w.includes(`Measure "${displayName}" lives on related element`))) {
              warnings.push(`\u26A0 Measure "${displayName}" lives on related element \u2014 no auto Sum() metric on the fact (Sigma metrics are single-element). Aggregate it through the relationship in the workbook layer, or author the metric manually.`);
            }
          }
          continue;
        }
        {
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
            const _autoMetric = { id: sigmaShortId(), formula: `Sum([${displayName}])`, name: _autoMetricName(displayName) };
            if (_autoFmt)
              _autoMetric.format = _autoFmt;
            factEl.metrics.push(_autoMetric);
          }
        }
        continue;
      }
      {
        if (joinTableIndex && _tryJoinCoalesce(caption, formula))
          continue;
        let lod = tableauParseLOD(formula);
        let lodOuterAgg = null;
        if (!lod) {
          const wrapped = _stripOuterAggAroundLod(formula);
          if (wrapped) {
            lod = tableauParseLOD(wrapped.inner);
            lodOuterAgg = wrapped.aggFunc;
          }
        }
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
            const suggestion = _suggestCrossTableLodSql2(lod, lodDimsResolved, caption);
            if (suggestion) {
              warnings.push(`\u26A0 LOD "${caption}" (${lod.lodType}) groups by a dimension-table column (cross-table grain) \u2014 not auto-wired yet. Create a Custom SQL element in Sigma with:
${suggestion}
  then relate it back to the base on the grouping column(s). (Auto-wiring tracked: beads-sigma-hnx0.)`);
            } else {
              warnings.push(`\u26A0 LOD "${caption}" (${lod.lodType}) groups by a dimension-table column (cross-table grain); not mechanizable as a single-table helper \u2014 needs manual Sigma authoring. Skipped.`);
            }
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
              if (m.onFact === false) {
                ok = false;
                warnings.push(`\u26A0 LOD "${caption}" view-context dim [${dn}] lives on related element "${m.el?.name || (m.el?.source?.path || []).slice(-1)[0] || "?"}", not the fact \u2014 refusing a wrong-FROM helper for this view context. Author as grouped Custom SQL joining fact\u2192dim if needed.`);
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
            if (lodOuterAgg)
              warnings.push(`\u2139 LOD "${caption}" was wrapped by ${lodOuterAgg}({\u2026}); emitted the row-level LOD value \u2014 apply ${lodOuterAgg} as the measure's aggregation in the workbook (verify the number vs source).`);
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
        if (!c.name) {
          const tail = typeof c.formula === "string" && (c.formula.match(/^\[[^\]]+\/([^\]\/]+)\]$/) || [])[1];
          if (tail) {
            exactNames.add(tail.toLowerCase());
            const tk = normKey(tail);
            if (tk && !(tk in normIndex))
              normIndex[tk] = tail;
          }
          continue;
        }
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
        warnings.push(`\u2139 Reconciled ${rewrites} calc-formula field reference(s) to their SQL-alias column names (caption\u2194alias) on "${factTableName}".`);
      }
      if (factEl?.source?.kind === "sql") {
        const nkey = (s) => s.replace(/[^a-zA-Z0-9]+/g, "").toLowerCase();
        const refToOutId = {};
        for (const c of factEl.columns || []) {
          const fm = typeof c.formula === "string" && c.formula.match(/^\[Custom SQL\/([^\]]+)\]$/);
          if (!fm)
            continue;
          const outId = fm[1];
          for (const k of [c.name, outId]) {
            const nk = k && nkey(k);
            if (nk && !(nk in refToOutId))
              refToOutId[nk] = outId;
          }
        }
        let qcount = 0;
        const qualify = (formula, ownName) => {
          if (typeof formula !== "string")
            return formula;
          return formula.replace(/\[([^\]]+)\]/g, (m, ref) => {
            if (/^Custom SQL\//.test(ref))
              return m;
            if (ownName && ref.toLowerCase() === ownName.toLowerCase())
              return m;
            const outId = refToOutId[nkey(ref)];
            if (!outId)
              return m;
            qcount++;
            return `[Custom SQL/${outId}]`;
          });
        };
        const isAlias = (f) => typeof f === "string" && /^\[Custom SQL\/[^\]]+\]$/.test(f);
        for (const c of factEl.columns || []) {
          if (isAlias(c.formula))
            continue;
          c.formula = qualify(c.formula, c.name);
        }
        for (const mtr of factEl.metrics || [])
          mtr.formula = qualify(mtr.formula, mtr.name);
        if (qcount > 0) {
          warnings.push(`\u2139 Qualified ${qcount} sibling reference(s) to [Custom SQL/\u2026] form on "${factEl.name || "Custom SQL"}" (kind:'sql' columns resolve only via the Custom SQL/ prefix).`);
        }
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
          warnings.push(`\u2139 Dropped ${n} self-referential rename calc(s) on "${factTableName}" (redundant \u2014 the physical column is already present).`);
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
          warnings.push(`\u2139 Promoted ${promoted} aggregate-ratio calc column(s) to metrics on "${factTableName}" (they reference aggregate metrics \u2014 invalid as row-level columns).`);
        if (aggDims)
          warnings.push(`\u2139 "${factTableName}": ${aggDims} aggregate-derived dimension(s) (bucket an aggregate metric) \u2192 reported in result.workbookPatterns \u2014 CHART/grouped-element context only; group the viz by the binned aggregate (NOT a DM column or metric).`);
      }
      const valid = /* @__PURE__ */ new Set();
      for (const c of factEl.columns || []) {
        if (c.name)
          valid.add(c.name.toLowerCase());
        else {
          const tail = typeof c.formula === "string" && (c.formula.match(/^\[[^\]]+\/([^\]\/]+)\]$/) || [])[1];
          if (tail)
            valid.add(tail.toLowerCase());
        }
      }
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
        warnings.push(`\u2139 Dropped ${dropped.length} unresolvable calc column(s)/metric(s) on "${factTableName}" after caption\u2194alias reconciliation (see per-calc warnings above).`);
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
  if (droppedVcJoinRels.length > 0) {
    for (const drop of droppedVcJoinRels) {
      const orphanCaps = /* @__PURE__ */ new Set();
      for (const g of Object.keys(guidOwnerRel)) {
        if (guidOwnerRel[g] !== drop.relName)
          continue;
        const cap = guidCaption[g];
        if (cap)
          orphanCaps.add(cap.toUpperCase());
      }
      if (orphanCaps.size === 0)
        continue;
      const refsOrphan = (f) => {
        if (typeof f !== "string")
          return null;
        for (const m of f.match(/\[([^\]]+)\]/g) || []) {
          const ref = m.slice(1, -1);
          const last = ref.includes("/") ? ref.split("/").pop() || ref : ref;
          if (orphanCaps.has(last.toUpperCase()))
            return last;
        }
        return null;
      };
      const targetEl = elements.find((e) => ((e.source?.path || [])[(e.source?.path || []).length - 1] || "") === drop.target);
      const culled = [];
      for (const el of elements) {
        if (el !== targetEl) {
          for (let i = (el.columns || []).length - 1; i >= 0; i--) {
            const c = el.columns[i];
            const hit = refsOrphan(c.formula);
            if (hit) {
              culled.push(`column "${c.name || hit}"`);
              el.columns.splice(i, 1);
              el.order = (el.order || []).filter((id) => id !== c.id);
            }
          }
        }
        const mets = el.metrics;
        if (Array.isArray(mets)) {
          for (let i = mets.length - 1; i >= 0; i--) {
            const hit = refsOrphan(mets[i].formula);
            if (hit) {
              culled.push(`metric "${mets[i].name || hit}"`);
              mets.splice(i, 1);
            }
          }
        }
      }
      if (culled.length > 0) {
        warnings.push(`\u26A0 Dropped relationship ${drop.source} \u2192 ${drop.target}: culled ${culled.length} joined-side item(s) so the spec stays consistent \u2014 ${culled.join(", ")}. Recreate them after wiring the relationship manually.`);
      }
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
    const controlId = sanitizeControlId(sigmaDisplayName(p.name));
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
    const _paramLiteral = (s) => {
      const t = (s || "").trim();
      if (!t)
        return "";
      let m = t.match(/^"((?:[^"\\]|\\.)*)"$/);
      if (m)
        return m[1].replace(/\\(.)/g, "$1");
      m = t.match(/^#\s*([^#]+?)\s*#$/);
      if (m)
        return m[1];
      if (/^-?\d+(?:\.\d+)?$/.test(t) || /^(?:true|false)$/i.test(t))
        return t;
      return "";
    };
    const _isoDateValue = (s) => {
      const m = (s || "").match(/^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2})(?::(\d{2}))?)?/);
      if (!m)
        return "";
      return m[2] ? `${m[1]}T${m[2]}:${m[3] || "00"}` : m[1];
    };
    // True parameter default: the .twb's own current value (value attr, or the
    // initial-value calc when it is a plain literal). Empty when the workbook
    // carries neither \u2014 every branch below falls back to its old shape then.
    const _rawCur = (p.currentValue || "").trim();
    const paramDefault = (/^#.*#$/.test(_rawCur) ? _paramLiteral(_rawCur) : _rawCur) || _paramLiteral(p.defaultVal);
    if (p.domainType === "list" && p.members.length > 0) {
      const aliasMap = p.memberAliases || {};
      const labels = p.members.map((v) => aliasMap[v] || v);
      const hasLabels = p.members.some((v) => aliasMap[v] && aliasMap[v] !== v);
      const defSelected = paramDefault && p.members.includes(paramDefault) ? [paramDefault] : [];
      controls.push({
        kind: "control",
        controlId,
        id: sigmaShortId() + "con",
        controlType: "list",
        mode: "include",
        selectionMode: "single",
        values: defSelected,
        source: { kind: "manual", valueType: "text", values: p.members, ...hasLabels ? { labels } : {} }
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 list control${hasLabels ? ` (${Object.keys(aliasMap).length} member alias(es) \u2192 labels[])` : ""}${defSelected.length ? ` (default "${defSelected[0]}" from the workbook's current value)` : ""}`);
    } else if (p.type === "date" || p.type === "datetime") {
      const isoDef = _isoDateValue(paramDefault);
      if (isoDef) {
        controls.push({
          kind: "control",
          controlId,
          id: sigmaShortId() + "con",
          controlType: "date",
          mode: "=",
          value: isoDef
        });
        warnings.push(`\u2139 Parameter "${p.name}" \u2192 date control (default ${isoDef} from the workbook's current value)`);
      } else {
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
      }
    } else if (p.type === "real" || p.type === "integer" || p.domainType === "range") {
      const numDef = paramDefault !== "" && Number.isFinite(Number(paramDefault)) ? Number(paramDefault) : null;
      if (numDef !== null && p.domainType !== "range") {
        controls.push({
          kind: "control",
          controlId,
          id: sigmaShortId() + "con",
          controlType: "number",
          mode: "=",
          value: numDef,
          includeNulls: "when-no-value-is-selected"
        });
        warnings.push(`\u2139 Parameter "${p.name}" \u2192 number control (default ${numDef} from the workbook's current value)`);
      } else {
        controls.push({
          kind: "control",
          controlId,
          id: sigmaShortId() + "con",
          controlType: "number-range"
        });
        warnings.push(`\u2139 Parameter "${p.name}" \u2192 number-range control${numDef !== null ? ` (workbook current value ${numDef} \u2014 range domain, no single-value default applied)` : ""}`);
      }
    } else {
      controls.push({
        kind: "control",
        controlId,
        id: sigmaShortId() + "con",
        controlType: "text",
        mode: "contains",
        ...paramDefault !== "" ? { value: paramDefault } : {}
      });
      warnings.push(`\u2139 Parameter "${p.name}" \u2192 text control${paramDefault !== "" ? ` (default "${paramDefault}" from the workbook's current value)` : ""}`);
    }
  }
  // controlId dedupe (mirror of buildMultiDatasourceModel's merge dedupe):
  // sigmaDisplayName collapses punctuation/case, so near-identical parameter
  // names ("Top N Sites" / "Top_N_Sites") mint the SAME controlId \u2014 and
  // duplicate ids hard-fail the DM POST. First control wins; drops are loud.
  {
    const seenControlIds = /* @__PURE__ */ new Set();
    for (let i = controls.length - 1; i >= 0; i--) {
      const key = String(controls[i].controlId ?? controls[i].id);
      if (!seenControlIds.has(key)) {
        seenControlIds.add(key);
        continue;
      }
      warnings.push(`\u26a0 Duplicate controlId "${key}" \u2014 two parameters normalize to the same control id; kept the first, dropped the duplicate control. Rename one parameter (or hand-author a second control with a distinct id) if both are needed.`);
      controls.splice(i, 1);
    }
  }
  const derivedEls = buildDerivedElements(elements, warnings);
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
  const sqlProvenance = elements.filter((e) => e.source?.kind === "sql").map((e) => ({
    elementId: e.id,
    elementName: e.name,
    originType: e._sqlOrigin || "unattributed",
    statement: e.source.statement
  }));
  elements.forEach((e) => {
    delete e._sqlOrigin;
  });
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
    ...relationshipCoverage ? { relationshipCoverage } : {},
    ...sqlProvenance.length ? { sqlProvenance } : {},
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
  convertTableauToSigma,
  firstTopLevelSelectIndex
};
