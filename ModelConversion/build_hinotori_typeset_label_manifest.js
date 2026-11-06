#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fail(message) {
  throw new Error(message);
}

function parseArgs(args) {
  const result = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    const value = args[i + 1];
    if (!['--vocabulary', '--temml', '--output'].includes(key) || !value || result[key]) {
      fail('Usage: build_hinotori_typeset_label_manifest.js --vocabulary FILE --temml FILE --output FILE');
    }
    result[key] = value;
  }
  if (Object.keys(result).length !== 3) {
    fail('Usage: build_hinotori_typeset_label_manifest.js --vocabulary FILE --temml FILE --output FILE');
  }
  return result;
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function decodeMathMLText(value) {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

function renderedScalars(mathML) {
  const nodes = [...mathML.matchAll(/<(?:mi|mo|mn)(?:\s[^>]*)?>(.*?)<\/(?:mi|mo|mn)>/gs)];
  return nodes
    .flatMap(match => [...decodeMathMLText(match[1])])
    .filter(character => character.codePointAt(0) !== 0xFE0E && character.codePointAt(0) !== 0xFE0F)
    .filter(character => !/^\s+$/u.test(character));
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const vocabularyBytes = fs.readFileSync(args['--vocabulary']);
  const temmlBytes = fs.readFileSync(args['--temml']);
  const vocabularyDocument = JSON.parse(vocabularyBytes.toString('utf8'));
  const labels = vocabularyDocument.labels;
  if (vocabularyDocument.version !== 'hinotori-v1' || !Array.isArray(labels) || labels.length !== 229 || new Set(labels).size !== 229) {
    fail('The input must be the exact, ordered Hinotori 229-label vocabulary.');
  }

  const context = {};
  vm.runInNewContext(temmlBytes.toString('utf8'), context, {filename: args['--temml']});
  const temml = context.temml;
  if (!temml || typeof temml.renderToString !== 'function' || temml.version !== '0.14.0') {
    fail('The selected Temml source is not the pinned 0.14.0 MathML renderer.');
  }

  const combiningScalars = new Map([
    ['\\dot', 0x0307],
    ['\\hat', 0x0302],
    ['\\overline', 0x0305],
    ['\\tilde', 0x0303],
    ['\\underline', 0x0332],
    ['\\vec', 0x20D7],
  ]);
  const structuralLabels = new Set(['\\frac']);
  const entries = labels.map((label, index) => {
    let kind;
    let renderInput = label;
    let scalar = null;
    if (structuralLabels.has(label)) {
      kind = 'math-structure';
      renderInput = '\\frac{a}{b}';
    } else if (combiningScalars.has(label)) {
      kind = 'unicode-combining';
      scalar = combiningScalars.get(label);
      renderInput = `${label}{x}`;
    } else {
      kind = 'unicode-glyph';
      if (label === '\\sqrt') renderInput = '\\sqrt{x}';
      const markup = temml.renderToString(renderInput, {xml: true, throwOnError: true});
      const scalars = renderedScalars(markup);
      if (label === '\\sqrt') {
        scalar = 0x221A;
      } else {
        if (scalars.length !== 1) {
          fail(`${label}: expected one rendered Unicode scalar, observed ${scalars.map(value => `U+${value.codePointAt(0).toString(16).toUpperCase()}`).join(', ') || 'none'}.`);
        }
        scalar = scalars[0].codePointAt(0);
      }
      if (!Number.isInteger(scalar) || scalar < 0 || scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
        fail(`${label}: renderer produced an invalid Unicode scalar.`);
      }
      return {index, label, kind, unicodeScalar: `U+${scalar.toString(16).toUpperCase().padStart(4, '0')}`, renderInput};
    }

    const markup = temml.renderToString(renderInput, {xml: true, throwOnError: true});
    if (kind === 'math-structure' && !/<mfrac\b/.test(markup)) {
      fail(`${label}: canonical expression did not render as a fraction structure.`);
    }
    return {
      index,
      label,
      kind,
      unicodeScalar: scalar === null ? null : `U+${scalar.toString(16).toUpperCase().padStart(4, '0')}`,
      renderInput,
    };
  });

  const counts = entries.reduce((result, entry) => {
    result[entry.kind] = (result[entry.kind] || 0) + 1;
    return result;
  }, {});
  if (counts['unicode-glyph'] !== 222 || counts['unicode-combining'] !== 6 || counts['math-structure'] !== 1 || entries.length !== 229) {
    fail(`Unexpected type partition: ${JSON.stringify(counts)}.`);
  }

  const manifest = {
    schema: 'firebird-symbol-rendering-kind-manifest-v1',
    vocabularyVersion: vocabularyDocument.version,
    vocabularySHA256: sha256(vocabularyBytes),
    renderer: 'Temml',
    rendererVersion: temml.version,
    rendererSHA256: sha256(temmlBytes),
    entries,
    counts,
  };
  const outputPath = path.resolve(args['--output']);
  const json = `${JSON.stringify(manifest, null, 2)}\n`;
  fs.writeFileSync(outputPath, json, {flag: 'wx'});
  process.stdout.write(`分類済み: ${entries.length} / 229 (${JSON.stringify(counts)})\nSHA-256: ${sha256(Buffer.from(json))}\n出力: ${outputPath}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`字形種別マニフェスト作成失敗: ${error.message}\n`);
  process.exitCode = 1;
}
