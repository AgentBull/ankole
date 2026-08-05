import { describe, expect, test } from 'bun:test'
import i18n from '../../common/i18n'
import { PROFILE_NAMES } from '../state/model-profiles-model'
import { modelProfileLabel } from './model-profiles-editor'

describe('model profile labels', () => {
  test('uses role names instead of fixed profile IDs', () => {
    const zh = i18n.getFixedT('zh-Hans-CN')
    const en = i18n.getFixedT('en-US')

    expect(PROFILE_NAMES.map(profile => modelProfileLabel(zh, profile))).toEqual([
      '主模型',
      '轻量模型',
      '复杂任务模型',
      '后台 Agent 任务默认模型',
      '图片输入兜底模型',
      '向量嵌入模型',
      '检索重排模型',
      '联网搜索模型',
      '网页读取模型',
      '图像生成模型'
    ])
    expect(PROFILE_NAMES.map(profile => modelProfileLabel(en, profile))).toEqual([
      'Primary model',
      'Lightweight model',
      'Complex work model',
      'Background Agent Job default model',
      'Vision fallback model',
      'Embedding model',
      'Reranking model',
      'Web search model',
      'Web fetch model',
      'Image generation model'
    ])
    expect(zh('common.clear')).toBe('清除')
    expect(en('common.clear')).toBe('Clear')
  })
})
