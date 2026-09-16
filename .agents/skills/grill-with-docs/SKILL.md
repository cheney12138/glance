---
name: grill-with-docs
description: 拷问式设计评审,并且边聊边把结论落成文档(词表 CONTEXT.md + 决策 ADR)。**只在用户显式要求时使用** —— 触发词:/grill-with-docs、"grill with docs"、"拷问我的方案并出文档"、"边聊边写文档"。不要自动触发。
---

# Grill with Docs

一次**拷问式**的设计评审:用提问把方案里没想清楚的地方逼出来,
同时把**已经定下来的东西**当场写成文档。两件事**同一轮里同时发生** —— 不是先聊完再补文档。

## 怎么跑

1. **先把两份规则的原文读进来**,按它们各自的要求执行(相对本文件的路径):
   - [`../grilling/SKILL.md`](../grilling/SKILL.md) —— 拷问的**节奏**:把设计画成一棵树,
     每轮只问**frontier**(前置问题都已定的那些),一轮把整个 frontier 问完,每题给出**推荐答案**,然后等回答。
   - [`../domain-modeling/SKILL.md`](../domain-modeling/SKILL.md) —— 落文档的**纪律**:词表 `CONTEXT.md`
     与决策 `docs/adr/` 的写法与格式(见同目录 `CONTEXT-FORMAT.md` / `ADR-FORMAT.md`)。
2. **每一轮结束就落一次文档**(这是本 skill 与单纯"拷问"的唯一区别):
   - 定下的**术语** → 写进/改 `CONTEXT.md`;
   - 定下的**决策** → 写一条 ADR(**为什么这么定 + 当时否掉了什么**,不是"做了什么");
   - **没定下来的一个字都不写** —— 文档只记结论,不记过程 ✗。
3. **收尾输出三行**:
   - 本轮定了 N 条决策(逐条一句);
   - 新增/修改了哪些文档(路径);
   - frontier 里**还没解决**的问题(这些就是下一轮的输入)。

## 移植说明(从 Claude Code 搬过来的)

原版正文只有一句 "Call the Skill tool twice, for `grilling` and `domain-modeling`",
那是 Claude Code 的调用方式;pi 里没有那个工具,**skill 是靠读 SKILL.md 加载的**,所以改成了上面的显式读文件。
原 frontmatter 的 `disable-model-invocation: true` 也是 Claude 专有字段,已删除,
改为在 description 里写死"只在显式要求时使用"。
