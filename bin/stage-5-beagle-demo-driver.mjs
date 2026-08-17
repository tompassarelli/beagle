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
    const sourcePath = sourceEdit === 'private-implementation' && source === 'foundation.bgl'
      ? path.join(corpus, 'mutations', 'private-implementation', source)
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

async function buildExecutable(sourceRoot, output, label) {
  await mkdir(output, { recursive: true })
  const executable = path.join(output, 'run-score')
  await runBeagle([
    'native-exe',
    '--out', executable,
    '--artifacts', output,
    '--entry', 'corpus.app/run-score',
    ...sources.map((source) => path.relative(root, path.join(sourceRoot, source))),
  ], label)
  return executable
}

function runExecutable(executable, label) {
  return new Promise((resolve, reject) => {
    execFile(executable, { cwd: root, timeout: 10_000 }, (error, stdout, stderr) => {
      if (error === null) {
        resolve({ status: 0, stdout, stderr })
        return
      }
      if (typeof error.code === 'number' && error.signal === null) {
        resolve({ status: error.code, stdout, stderr })
        return
      }
      reject(new Error(`Stage 5 ${label} execution failed: ${error.message}`, { cause: error }))
    })
  })
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
  if (sourceEdit !== 'private-implementation') {
    throw new Error('Stage 5 Beagle driver accepts only sourceEdit=private-implementation')
  }

  const scratch = await mkdtemp(path.join(root, '.beagle-stage5-demo-'))
  try {
    const baselineRoot = await copyCorpus(path.join(scratch, 'baseline-sources'), 'baseline')
    const candidateRoot = await copyCorpus(path.join(scratch, 'candidate-sources'), sourceEdit)
    const baselineOutput = path.join(scratch, 'baseline-build')
    const candidateOutput = path.join(scratch, 'candidate-build')
    const singletonOutput = path.join(scratch, 'singleton-build')

    const baselineExecutable = await buildExecutable(
      baselineRoot, baselineOutput, 'baseline cold compile',
    )
    const candidateExecutable = await buildExecutable(
      candidateRoot, candidateOutput, 'candidate cold compile',
    )
    await build(candidateRoot, singletonOutput, 'affected singleton cold compile', true)

    const [baselineFacts, candidateFacts, baselineSource, candidateSource, candidateProgram,
      candidateNativeProgram, singletonProgram, candidateReport, singletonReport,
      baselineBehavior, candidateBehavior] = await Promise.all([
      readRequiredText(baselineOutput, 'source.facts'),
      readRequiredText(candidateOutput, 'source.facts'),
      readFile(path.join(baselineRoot, 'foundation.bgl')),
      readFile(path.join(candidateRoot, 'foundation.bgl')),
      readArtifact(candidateOutput, 'module.native-program'),
      readRequiredText(candidateOutput, 'module.native-program.sha256'),
      readArtifact(singletonOutput, 'module.native-program'),
      readRequiredText(candidateOutput, 'report.txt'),
      readRequiredText(singletonOutput, 'report.txt'),
      runExecutable(baselineExecutable, 'baseline behavior'),
      runExecutable(candidateExecutable, 'candidate behavior'),
    ])
    const baselineUnits = semanticUnits(baselineFacts)
    const candidateUnits = semanticUnits(candidateFacts)
    const cone = exactCone(baselineUnits, candidateUnits)
    const singleton = 'corpus.foundation/private-offset'
    const baselineNames = baselineUnits.map((unit) => `${unit.module}/${unit.name}`)
    const candidateNames = candidateUnits.map((unit) => `${unit.module}/${unit.name}`)
    const unaffectedUnits = candidateNames.filter((unit) => !cone.includes(unit))
    const baselineSourceOid = digest(baselineSource)
    const sourceOid = digest(candidateSource)
    const programOid = `sha256:${candidateNativeProgram.trim().replace(/^sha256:/, '')}`
    const singletonProgramOid = digest(singletonProgram.bytes)

    if (!candidateReport.includes('result PASS') || !singletonReport.includes('result PASS')) {
      throw new Error('candidate or affected singleton cold compile did not report result PASS')
    }
    if (programOid !== candidateProgram.digest) {
      throw new Error('candidate native program digest receipt does not match its bytes')
    }
    if (baselineSourceOid === sourceOid) {
      throw new Error('private-implementation did not change the source bytes')
    }
    if (JSON.stringify(baselineNames) !== JSON.stringify(candidateNames)) {
      throw new Error('private-implementation changed semantic unit identities')
    }
    if (cone.length === 0) {
      throw new Error('Stage 5 refuses an empty semantic invalidation cone')
    }
    if (cone.length !== 1 || cone[0] !== singleton) {
      throw new Error(`private-implementation changed the wrong semantic cone: ${cone.join(', ')}`)
    }
    if (!cone.includes(singleton)) {
      throw new Error(`affected singleton ${singleton} is outside the invalidation cone`)
    }
    if (baselineBehavior.status !== 16 || candidateBehavior.status !== 17) {
      throw new Error(
        `private-implementation behavior delta was ${baselineBehavior.status} -> ` +
        `${candidateBehavior.status}, expected 16 -> 17`,
      )
    }

    return {
      source: sourceOid,
      program: programOid,
      compiler: await compilerIdentity(),
      abi: 'lp64',
      unitPlan: {
        sourceModule: 'corpus.foundation',
        singleton,
        exactCone: cone,
        unaffectedUnits,
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
        singleton,
        source: 'corpus.foundation/foundation.bgl',
        program: singletonProgramOid,
        byteLength: singletonProgram.byteLength,
        report: 'result PASS',
      },
      behaviorDelta: {
        entry: 'corpus.app/run-score',
        baseline: baselineBehavior.status,
        candidate: candidateBehavior.status,
        visible: true,
      },
    }
  } finally {
    await rm(scratch, { recursive: true, force: true })
  }
}
