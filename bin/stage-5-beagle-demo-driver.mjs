#!/usr/bin/env node

import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cp, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const corpus = path.join(root, 'bin', 'test', 'branch-compile-corpus')
const sources = ['foundation.bgl', 'feature.bgl', 'independent.bgl', 'app.bgl']
const entries = [
  'corpus.app/run-score',
  'corpus.app/run-stable',
  'corpus.app/run-independent',
]
const phaseTimeoutMs = 180_000

function digest(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
}

async function runBeagle(args, phase) {
  try {
    return await execFileAsync('nice', ['-n', '19', path.join(root, 'bin', 'beagle'), ...args], {
      cwd: root,
      maxBuffer: 32 * 1024 * 1024,
      timeout: phaseTimeoutMs,
    })
  } catch (error) {
    const detail = [error.stdout, error.stderr, error.message]
      .filter((value) => typeof value === 'string' && value.length > 0)
      .join('\n')
    throw new Error(`Stage 5 Beagle ${phase} failed: ${detail}`, { cause: error })
  }
}

async function copyCorpus(destination, sourceEdit) {
  await mkdir(destination, { recursive: true })
  for (const source of sources) {
    const sourcePath = sourceEdit === 'comment-layout' && source === 'foundation.bgl'
      ? path.join(corpus, 'mutations', 'comment-layout', source)
      : path.join(corpus, 'corpus', source)
    await cp(sourcePath, path.join(destination, source))
  }
  return destination
}

async function build(sourceRoot, output, label, singleton = false) {
  const args = [
    'build',
    '--materializer', 'c17',
    '--out', output,
  ]
  if (!singleton) {
    for (const entry of entries) args.push('--entry', entry)
    for (const source of sources) args.push(path.relative(root, path.join(sourceRoot, source)))
  } else {
    args.push(path.relative(root, path.join(sourceRoot, 'foundation.bgl')))
  }
  await runBeagle(args, label)
}

async function readArtifact(output, name) {
  const bytes = await readFile(path.join(output, name))
  return { bytes, digest: digest(bytes), byteLength: bytes.byteLength }
}

async function readRequiredText(output, name) {
  return readFile(path.join(output, name), 'utf8')
}

function semanticUnits(facts) {
  const bySubject = new Map()
  for (const line of facts.split('\n')) {
    if (line.length === 0) continue
    const [subject, predicate, kind, value] = line.split('\t')
    if (!subject || !predicate || !kind || value === undefined) continue
    if (!predicate.startsWith('semantic-unit-')) continue
    const unit = bySubject.get(subject) ?? {}
    if (predicate === 'semantic-unit-kind' || predicate === 'semantic-unit-name' ||
        predicate === 'semantic-unit-module' || predicate === 'semantic-unit-sha256') {
      unit[predicate.slice('semantic-unit-'.length)] = value
      bySubject.set(subject, unit)
    }
  }
  return [...bySubject.values()]
    .filter((unit) => unit.kind && unit.name && unit.module && unit.sha256)
    .sort((left, right) => `${left.module}/${left.name}`.localeCompare(`${right.module}/${right.name}`))
}

function exactCone(baselineUnits, candidateUnits) {
  const baseline = new Map(baselineUnits.map((unit) => [`${unit.module}/${unit.name}`, unit]))
  return candidateUnits
    .filter((unit) => baseline.get(`${unit.module}/${unit.name}`)?.sha256 !== unit.sha256)
    .map((unit) => `${unit.module}/${unit.name}`)
}

async function compilerIdentity() {
  const { stdout } = await execFileAsync('git', ['-C', root, 'rev-parse', 'HEAD'], {
    cwd: root,
    timeout: 10_000,
  })
  return `git:${stdout.trim()}`
}

export async function runStage5ColdCompile({ sourceEdit } = {}) {
  if (sourceEdit !== 'comment-layout') {
    throw new Error('Stage 5 Beagle driver accepts only sourceEdit=comment-layout')
  }

  const scratch = await mkdtemp(path.join(root, '.beagle-stage5-demo-'))
  try {
    const sourceRoot = path.join(scratch, 'sources')
    const baselineRoot = await copyCorpus(sourceRoot, 'baseline')
    const baselineOutput = path.join(scratch, 'baseline-build')
    const candidateOutput = path.join(scratch, 'candidate-build')
    const singletonOutput = path.join(scratch, 'singleton-build')

    await build(baselineRoot, baselineOutput, 'baseline cold compile')
    await copyCorpus(sourceRoot, sourceEdit)
    const candidateRoot = sourceRoot
    await build(candidateRoot, candidateOutput, 'candidate cold compile')
    await build(candidateRoot, singletonOutput, 'affected singleton cold compile', true)

    const [baselineFacts, candidateFacts, candidateSource, candidateProgram,
      candidateNativeProgram, singletonProgram, candidateReport] = await Promise.all([
      readRequiredText(baselineOutput, 'source.facts'),
      readRequiredText(candidateOutput, 'source.facts'),
      readFile(path.join(candidateRoot, 'foundation.bgl')),
      readArtifact(candidateOutput, 'module.native-program'),
      readRequiredText(candidateOutput, 'module.native-program.sha256'),
      readArtifact(singletonOutput, 'module.native-program'),
      readRequiredText(candidateOutput, 'report.txt'),
    ])
    const baselineUnits = semanticUnits(baselineFacts)
    const candidateUnits = semanticUnits(candidateFacts)
    const cone = exactCone(baselineUnits, candidateUnits)
    const sourceOid = digest(candidateSource)
    const programOid = `sha256:${candidateNativeProgram.trim().replace(/^sha256:/, '')}`
    const singletonProgramOid = digest(singletonProgram.bytes)

    if (!candidateReport.includes('result PASS')) {
      throw new Error('candidate cold compile did not report result PASS')
    }
    if (programOid !== candidateProgram.digest) {
      throw new Error('candidate native program digest receipt does not match its bytes')
    }
    if (cone.length !== 0) {
      throw new Error(`comment-layout changed semantic units unexpectedly: ${cone.join(', ')}`)
    }

    return {
      source: sourceOid,
      program: programOid,
      compiler: await compilerIdentity(),
      abi: 'lp64',
      unitPlan: {
        sourceModule: 'corpus.foundation',
        singleton: 'corpus.foundation',
        exactCone: cone,
        mode: 'cold',
      },
      coneInvalidation: {
        sourceEdit,
        sourceModule: 'corpus.foundation',
        exactCone: cone,
        sourceBytesChanged: true,
        semanticUnitsChanged: cone.length,
      },
      coldCompile: {
        status: 'PASS',
        singleton: 'corpus.foundation',
        source: 'corpus.foundation/foundation.bgl',
        program: singletonProgramOid,
        byteLength: singletonProgram.byteLength,
        report: 'result PASS',
      },
    }
  } finally {
    await rm(scratch, { recursive: true, force: true })
  }
}
