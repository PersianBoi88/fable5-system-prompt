# Claude Fable 5 — System Prompt

Claude Fable 5 的完整系统提示词，由越狱研究者 Pliny the Liberator 提取并公开。

## 文件说明

| 文件 | 行数 | 说明 |
|------|------|------|
| `CLAUDE-FABLE-5-full.md` | 1585 | 完整版，包含 claude.ai 网页端全部工具定义、搜索规则、artifact 规则等 |
| `CLAUDE-FABLE-5-lite.md` | 164 | 精简版，去掉了网页端专属部分，只保留行为 DNA（格式规则、语气、安全边界等） |

## 怎么用

**Claude Code / API 场景用 lite 版就够：**

```bash
claude --model claude-opus-4-8 --system-prompt-file CLAUDE-FABLE-5-lite.md -p "your prompt"
```

**我的实测结论：** 提示词能改变模型的行为风格（格式散文化、代码更完整），但不能改变输出质量。27 次对照实验，加不加提示词总体评分打平。详见小红书 @Cyrus宇。

## 来源

- 原始提取：Pliny the Liberator (GitHub, 2026-06-10)
- 复活实验：Jamieson O'Reilly (X, 2026-06-13)
- 独立验证：Cyrus (27 次对照实验, 2026-06-15)
