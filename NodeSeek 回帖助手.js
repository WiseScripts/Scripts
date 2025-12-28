// ==UserScript==
// @name         NodeSeek 回帖助手
// @namespace    http://tampermonkey.net/
// @version      0.1
// @description  自动标记已回复帖子 + 自动跳转楼层 + 倒序/增量同步 + 快捷回复指令(动态分列)
// @author       Gemini & Endercat & Tune
// @match        https://www.nodeseek.com/*
// @grant        GM_setClipboard
// @grant        GM_addStyle
// @run-at       document-start
// @noframes
// ==/UserScript==

(function () {
  'use strict';

  // ==========================================
  // 防线 1: 全局单例锁
  // ==========================================
  const GLOBAL_FLAG = '__NODESEEK_HELPER_LOADED__';
  if (window[GLOBAL_FLAG]) return;
  window[GLOBAL_FLAG] = true;

  // ==========================================
  // 配置与常量
  // ==========================================
  const STORAGE_KEY = 'nodeseek_replied_posts';
  const SYNC_TIME_KEY = 'nodeseek_last_sync_time';

  // 【核心配置】推荐设置为 3 栏，配合智能平衡算法效果最佳
  const COLUMN_COUNT = 3;

  let currentUserId = null;
  let isSyncing = false;

  // 快捷回复数据 (顺序不重要，脚本会自动按高度平衡排序)
  const QUICK_REPLIES = [
    {
      id: "lottery",
      title: "🎉 抽奖专用",
      items: [
        "分母参与，谢谢楼主！", "参与抽奖，分母 +1。", "万一中了呢？感谢老板。",
        "重在参与，分母在此。", "老板大气，加个鸡腿！", "支持福利，老板发大财。",
        "老板太慷慨了，顶一下！", "吸吸欧气，希望这次能中。", "在此处留下我的欧气，期待中奖。",
        "虽然没中过，但还是要试试，感谢分享。", "分母也有梦想，冲冲冲！"
      ]
    },
    {
      id: "daily",
      title: "🌊 日常水贴",
      items: [
        "路过看看，顺便混个鸡腿。", "吃瓜群众，前排围观。", "插个眼，持续关注。",
        "确实，我也这么觉得。", "你说得对，但我选择观望。", "学到了，又涨了奇怪的知识。",
        "虽然看不懂，但感觉很厉害的样子。", "生命在于折腾，大佬继续。", "买鸡一时爽，吃灰一辈子。",
        "这就是大佬的世界吗？告辞。", "现在的 MJJ 越来越卷了。", "又被你水到了..."
      ]
    },
    {
      id: "common",
      title: "🚀 快速简短",
      items: ["BD", "来了老哥。", "路过帮顶。", "火钳刘明。"]
    },
    {
      id: "info",
      title: "📡 情报",
      items: [
        "谢谢分享！", "感谢楼主分享，收藏了。", "前排围观，感谢大佬情报！", "马克一下，以后肯定用得着。"
      ]
    },
    {
      id: "review",
      title: "📝 测评",
      items: [
        "性价比很高，值得购买。", "已入一台，性能确实不错。", "蹲一个测评，看看线路稳不稳。",
        "价格不错，可惜没有需求，让给有缘人。", "手慢无，已经断货了。"
      ]
    },
    {
      id: "tech",
      title: "💻 技术",
      items: [
        "很详细的教程，加个鸡腿。", "技术大牛，分析得很透彻。", "支持原创，NodeSeek 有你更精彩！", "测评辛苦了，参考价值很高。"
      ]
    },
    {
      id: "trade",
      title: "💸 交易/拼车",
      items: [
        "帮顶，祝早出。", "排队，如果还没出请私信我。", "借楼同求，收一个同样的配置。", "诚心要，PM 一个联系方式。"
      ]
    }
  ];


  // ==========================================
  // 模块 1: 样式注入 (使用模板字符串动态生成)
  // ==========================================
  function initStyles() {
    const STYLE_ID = 'ns-helper-style';
    if (document.getElementById(STYLE_ID)) return;

    const css = `
            @keyframes nsNodeDetected { from { opacity: 0.99; } to { opacity: 1; } }
            .post-list-item { animation: nsNodeDetected 0.001s; }
            .content-item { animation: nsNodeDetected 0.001s; }
            .user-card { animation: nsNodeDetected 0.001s; }
            pre { animation: nsNodeDetected 0.001s; }
            .expression { animation: nsNodeDetected 0.001s; }

            .my-reply-mark { display: inline-flex; align-items: center; margin-left: 6px; cursor: help; vertical-align: middle; }
            .post-list-item.replied { border: 2px solid #388e3c !important; border-radius: 15px; transition: border 0.3s; margin-bottom: 12px !important; }

            .ns-floor-tag { display: inline-block; margin-left: 4px; padding: 0 4px; font-size: 11px; color: #388e3c; border: 1px solid #388e3c; border-radius: 4px; cursor: pointer; text-decoration: none; transition: all 0.2s; line-height: 1.4; }
            .ns-floor-tag:hover { background-color: #388e3c; color: #fff; }
            .dark-layout .ns-floor-tag { color: #66bb6a; border-color: #66bb6a; }
            .dark-layout .ns-floor-tag:hover { background-color: #66bb6a; color: #222; }

            .ns-code-wrapper { position: relative; }
            .ns-copy-btn { position: absolute; top: 5px; right: 5px; background: rgba(255, 255, 255, 0.8); border: 1px solid #ccc; border-radius: 4px; padding: 2px 8px; font-size: 12px; color: #333; cursor: pointer; opacity: 0; transition: opacity 0.2s; z-index: 10; }
            .ns-code-wrapper:hover .ns-copy-btn { opacity: 1; }
            [data-theme="dark"] .ns-copy-btn { background: rgba(50, 50, 50, 0.8); color: #ccc; border-color: #555; }

            .ns-sync-btn { margin-left: 5px; cursor: pointer; color: #007AFF; font-size: 12px; border: 1px solid #007AFF; padding: 1px 6px; border-radius: 10px; transition: all 0.2s; display: inline-block; user-select: none; }
            .ns-sync-btn:hover { background: #007AFF; color: #fff; }
            .ns-sync-btn.loading { opacity: 0.6; cursor: wait; }

            /* --- 快捷指令菜单样式 --- */
            .ns-qr-btn { cursor: pointer; user-select: none; transition: all 0.2s; font-weight: bold; color: #ff5f5f; }
            .ns-qr-btn:hover { color: #ff2b2b; }

            .ns-qr-panel {
                position: absolute; bottom: 40px; left: 0; z-index: 999;
                background: #fff; border: 1px solid #ddd; border-radius: 8px;
                box-shadow: 0 4px 20px rgba(0,0,0,0.2);
                padding: 15px;
                width: ${COLUMN_COUNT * 200}px; /* 动态宽度 */
                display: none;
                max-height: 80vh; overflow-y: auto;
            }
            .dark-layout .ns-qr-panel { background: #2d2d2d; border-color: #444; }
            .ns-qr-panel.show { display: block; animation: nsFadeInUp 0.2s; }
            @keyframes nsFadeInUp { from { opacity:0; transform: translateY(10px); } to { opacity:1; transform: translateY(0); } }

            /* Grid 布局 */
            .ns-qr-container {
                display: grid;
                grid-template-columns: repeat(${COLUMN_COUNT}, 1fr);
                gap: 15px;
                align-items: start; /* 顶部对齐，关键 */
            }

            .ns-qr-category { margin-bottom: 15px; break-inside: avoid; }

            .ns-qr-title {
                font-size: 13px; font-weight: bold; color: #666;
                margin-bottom: 8px; padding-bottom: 4px;
                border-bottom: 2px solid #eee;
            }
            .dark-layout .ns-qr-title { color: #aaa; border-color: #444; }

            .ns-qr-category.highlight .ns-qr-title { color: #007AFF; border-bottom-color: #007AFF; }
            .ns-qr-category.highlight .ns-qr-item { background: #f0f9ff; border-left: 2px solid #007AFF; }
            .dark-layout .ns-qr-category.highlight .ns-qr-item { background: #1a2733; border-left: 2px solid #007AFF; }

            .ns-qr-grid { display: flex; flex-direction: column; gap: 6px; }

            .ns-qr-item {
                padding: 6px 8px; background: #f9f9f9; border-radius: 4px;
                font-size: 12px; cursor: pointer; transition: all 0.2s;
                color: #333; border: 1px solid transparent;
                white-space: normal; line-height: 1.4;
            }
            .ns-qr-item:hover { background: #e0f2fe; color: #007AFF; transform: translateX(2px); }
            .dark-layout .ns-qr-item { background: #3a3a3a; color: #ccc; }
            .dark-layout .ns-qr-item:hover { background: #1a3c5e; color: #5aa9fa; }

            .ns-toast { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background: rgba(0, 0, 0, 0.8); color: white; padding: 15px 25px; border-radius: 8px; font-size: 14px; z-index: 10000; animation: nsFadeIn 0.3s; pointer-events: none; text-align: center; }
            @keyframes nsFadeIn { from { opacity:0; transform: translate(-50%, -40%); } to { opacity:1; transform: translate(-50%, -50%); } }
        `;

    if (typeof GM_addStyle !== 'undefined') {
      GM_addStyle(css);
    } else {
      const style = document.createElement('style');
      style.id = STYLE_ID;
      style.innerHTML = css;
      (document.head || document.documentElement).appendChild(style);
    }
  }

  // ==========================================
  // 模块 2: 数据存取
  // ==========================================
  const saveReplyState = (postId, floorId) => {
    try {
      const data = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
      let records = data[postId];
      if (!Array.isArray(records)) records = [];
      const fid = parseInt(floorId);
      if (!isNaN(fid) && !records.includes(fid)) {
        records.push(fid);
        records.sort((a, b) => a - b);
        data[postId] = records;
        localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
        return true;
      }
    } catch (e) { }
    return false;
  };
  const getReplyData = () => { try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); } catch { return {}; } };
  const getLastSyncTime = () => parseInt(localStorage.getItem(SYNC_TIME_KEY) || '0');
  const setLastSyncTime = (ts) => localStorage.setItem(SYNC_TIME_KEY, ts.toString());
  const resetSyncTime = () => localStorage.removeItem(SYNC_TIME_KEY);
  const showToast = (msg, duration = 2000) => {
    const t = document.createElement('div');
    t.className = 'ns-toast';
    t.innerText = msg;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), duration);
  };
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const formatTime = (ts) => new Date(ts * 1000).toLocaleString();

  // ==========================================
  // 模块 3: 核心爬虫
  // ==========================================
  async function startSyncHistory(btn) {
    if (isSyncing || !currentUserId) return;
    isSyncing = true;
    const originalText = btn.innerText;
    btn.innerText = "⏳ 0%";
    btn.classList.add('loading');

    const lastTime = getLastSyncTime();
    let msg = lastTime > 0 ? `🚀 增量同步... (截止: ${formatTime(lastTime)})` : "🚀 全量同步 (初次运行)...";
    showToast(msg, 3000);

    let page = 1;
    let newCount = 0;
    let hasMore = true;
    let maxTimeInSession = lastTime;
    let forceFullSync = false;

    while (hasMore) {
      try {
        btn.innerText = `⏳ P${page}`;
        const res = await fetch(`/api/content/list-comments?uid=${currentUserId}&page=${page}`);
        if (res.status === 429) { await sleep(3000); continue; }

        const json = await res.json();
        if (json && json.comments && json.comments.length > 0) {
          for (const item of json.comments) {
            const itemTime = item.created_at || 0;
            if (itemTime > maxTimeInSession) maxTimeInSession = itemTime;
            if (lastTime > 0 && itemTime <= lastTime && !forceFullSync) {
              await sleep(100);
              const userConfirm = confirm(`✅ 增量同步已完成。\n是否继续深度扫描以修复旧数据的楼层显示？`);
              if (userConfirm) { forceFullSync = true; showToast("🚀 深度修复中...", 3000); }
              else { hasMore = false; break; }
            }
            if (item.post_id && item.floor_id) {
              if (saveReplyState(item.post_id, item.floor_id)) newCount++;
            }
          }
          if (!hasMore) break;
          page++; await sleep(200);
        } else { hasMore = false; }
        if (page > 500) hasMore = false;
      } catch (e) { await sleep(1000); }
    }

    if (maxTimeInSession > lastTime) setLastSyncTime(maxTimeInSession);
    isSyncing = false;
    btn.innerText = "✅ 完成";
    btn.classList.remove('loading');
    setTimeout(() => { btn.innerText = originalText; }, 3000);
    showToast(`🎉 同步完成！\n新增: ${newCount} 条记录`, 4000);
    document.querySelectorAll('.post-list-item').forEach(processPostListItem);
  }
  // 获取当前帖子的分类 ID
  const getCurrentCategory = () => {
    const catLink = document.querySelector('.content-category a[href^="/categories/"]');
    if (catLink) {
      const match = catLink.getAttribute('href').match(/\/categories\/(\w+)/);
      if (match) return match[1];
    }
    return null;
  };
  // ==========================================
  // 模块 4: 快捷指令逻辑 (瀑布流平衡算法)
  // ==========================================

  const insertTextToEditor = (text) => {
    // 尝试获取 CodeMirror 实例
    const cmElement = document.querySelector('.CodeMirror');
    if (cmElement && cmElement.CodeMirror) {
      const cm = cmElement.CodeMirror;
      const doc = cm.getDoc();
      const cursor = doc.getCursor();
      doc.replaceRange(text, cursor);
      cm.focus();
    } else {
      // 降级方案：execCommand
      const textarea = document.querySelector('.CodeMirror textarea') || document.querySelector('#editor-body textarea');
      if (textarea) {
        textarea.focus();
        const success = document.execCommand('insertText', false, text);
        if (!success) {
          textarea.value += text;
          // 触发 input 事件让 Vue 感知
          textarea.dispatchEvent(new Event('input', { bubbles: true }));
        }
      } else {
        showToast("❌ 未找到编辑器");
      }
    }
  };

  // 智能分组算法：将数据分配到 N 列，使高度尽可能相等
  const getBalancedColumns = (data, colCount) => {
    // 1. 计算每个分类的“视觉权重” (标题按 2 行算，每条内容 1 行)
    const weightedData = data.map(cat => ({
      ...cat,
      weight: cat.items.length + 2
    }));

    // 2. 按权重从大到小排序 (贪心算法核心：先放大的)
    weightedData.sort((a, b) => b.weight - a.weight);

    // 3. 初始化列桶
    const cols = Array.from({ length: colCount }, () => ({ items: [], totalWeight: 0 }));

    // 4. 依次分配到当前最矮的那一列
    weightedData.forEach(cat => {
      // 找到当前 totalWeight 最小的列
      let minCol = cols[0];
      for (let i = 1; i < cols.length; i++) {
        if (cols[i].totalWeight < minCol.totalWeight) {
          minCol = cols[i];
        }
      }
      minCol.items.push(cat);
      minCol.totalWeight += cat.weight;
    });

    // 返回分好组的数据
    return cols.map(c => c.items);
  };

  const processQuickReplyUI = (node) => {
    if (node.querySelector('.ns-qr-btn')) return;

    const btnDiv = document.createElement('div');
    btnDiv.className = 'exp-item ns-qr-btn';
    btnDiv.innerText = '⚡快捷指令';
    btnDiv.title = '点击展开常用回复';

    const panel = document.createElement('div');
    panel.className = 'ns-qr-panel';

    const container = document.createElement('div');
    container.className = 'ns-qr-container';

    const currentCat = getCurrentCategory();

    // 【应用算法】获取平衡后的列数据
    const balancedCols = getBalancedColumns(QUICK_REPLIES, COLUMN_COUNT);

    // 渲染列
    balancedCols.forEach(colItems => {
      const colDiv = document.createElement('div');

      colItems.forEach(cat => {
        const catDiv = document.createElement('div');
        catDiv.className = 'ns-qr-category';

        if (currentCat && cat.id === currentCat) {
          catDiv.classList.add('highlight');
        }

        const titleDiv = document.createElement('div');
        titleDiv.className = 'ns-qr-title';
        titleDiv.innerText = cat.title;
        catDiv.appendChild(titleDiv);

        const listDiv = document.createElement('div');
        listDiv.className = 'ns-qr-grid';

        cat.items.forEach(reply => {
          const itemDiv = document.createElement('div');
          itemDiv.className = 'ns-qr-item';
          itemDiv.innerText = reply;
          itemDiv.onclick = (e) => {
            e.stopPropagation();
            insertTextToEditor(reply);
            panel.classList.remove('show');
          };
          listDiv.appendChild(itemDiv);
        });

        catDiv.appendChild(listDiv);
        colDiv.appendChild(catDiv);
      });
      container.appendChild(colDiv);
    });

    panel.appendChild(container);

    btnDiv.onclick = (e) => {
      e.stopPropagation();
      document.querySelectorAll('.ns-qr-panel.show').forEach(p => {
        if (p !== panel) p.classList.remove('show');
      });
      panel.classList.toggle('show');
    };

    document.addEventListener('click', (e) => {
      if (!panel.contains(e.target) && !btnDiv.contains(e.target)) {
        panel.classList.remove('show');
      }
    });

    node.appendChild(btnDiv);
    if (window.getComputedStyle(node).position === 'static') {
      node.style.position = 'relative';
    }
    node.appendChild(panel);
  };


  // ==========================================
  // 模块 5: DOM 处理器 (UI渲染)
  // ==========================================
  const processUserCard = (node, retry = 0) => {
    if (!currentUserId) {
      const link = node.querySelector('a[href^="/space/"]');
      if (link) {
        const match = link.getAttribute('href').match(/\/space\/(\d+)/);
        if (match) {
          currentUserId = match[1];
          document.querySelectorAll('.content-item').forEach(processCommentItem);
        }
      }
    }
    if (currentUserId) {
      const menuDiv = node.querySelector('.menu');
      if (menuDiv) {
        if (!node.querySelector('.ns-sync-btn')) {
          const btn = document.createElement('span');
          btn.className = 'ns-sync-btn';
          btn.innerText = '🔄 同步';
          btn.onmouseenter = () => {
            const t = getLastSyncTime();
            btn.title = t > 0 ? `上次同步: ${formatTime(t)}\n左键: 增量同步\n右键: 重置时间` : '点击开始全量扫描';
          };
          btn.onclick = (e) => { e.stopPropagation(); e.preventDefault(); startSyncHistory(btn); };
          btn.oncontextmenu = (e) => {
            e.stopPropagation(); e.preventDefault();
            if (confirm('⚠️ 重置同步时间？下次将全量扫描。')) { resetSyncTime(); showToast("🗑️ 时间已重置"); }
          };
          const userNameEl = menuDiv.querySelector('.Username');
          if (userNameEl) userNameEl.parentNode.insertBefore(btn, userNameEl.nextSibling);
          else menuDiv.appendChild(btn);
        }
      } else if (retry < 10) setTimeout(() => processUserCard(node, retry + 1), 500);
    } else if (retry < 5) setTimeout(() => processUserCard(node, retry + 1), 500);
  };

  const processCommentItem = (node) => {
    if (!currentUserId) return;
    const avatarLink = node.querySelector('.avatar-wrapper a[href^="/space/"]');
    if (!avatarLink) return;
    const match = avatarLink.getAttribute('href').match(/\/space\/(\d+)/);
    if (match && match[1] === currentUserId) {
      const postMatch = window.location.pathname.match(/\/post-(\d+)/);
      if (!postMatch) return;
      let floorId = null;
      const postLink = node.querySelector('a[href^="/post-"]');
      if (postLink) {
        const hashMatch = postLink.getAttribute('href').match(/#(\d+)$/);
        if (hashMatch) floorId = hashMatch[1];
      }
      if (!floorId) {
        const floorLink = node.querySelector('.floor-link');
        if (floorLink) floorId = floorLink.textContent.replace('#', '').trim();
      }
      if (postMatch[1] && floorId) saveReplyState(postMatch[1], floorId);
    }
  };

  const processPostListItem = (node) => {
    const titleLink = node.querySelector('.post-title a');
    if (!titleLink) return;
    const postId = titleLink.getAttribute('href').match(/\/post-(\d+)/)?.[1];
    const allData = getReplyData();
    const postData = allData[postId];
    if (postId && postData) {
      if (!node.classList.contains('replied')) node.classList.add('replied');
      let infoBar = node.querySelector('.post-info');
      if (!infoBar) return;

      let floors = Array.isArray(postData) ? postData : [];
      let floorContainer = node.querySelector('.ns-floors-container');
      if (!floorContainer) {
        floorContainer = document.createElement('span');
        floorContainer.className = 'ns-floors-container';
        infoBar.appendChild(floorContainer);
      }
      const newDataString = floors.join(',');
      if (floorContainer.getAttribute('data-floors') !== newDataString) {
        floorContainer.innerHTML = '';
        floorContainer.setAttribute('data-floors', newDataString);
        floors.forEach(floor => {
          const page = Math.ceil(floor / 10);
          const link = document.createElement('a');
          link.className = 'ns-floor-tag';
          link.textContent = floor;
          link.href = `/post-${postId}-${page}#${floor}`;
          link.title = `跳转到第 ${page} 页，第 ${floor} 楼`;
          link.onclick = (e) => e.stopPropagation();
          floorContainer.appendChild(link);
        });
      }
    }
  };

  const processCodeBlock = (preElement) => {
    if (preElement.parentNode.classList.contains('ns-code-wrapper')) return;
    const codeElement = preElement.querySelector('code');
    if (!codeElement) return;
    const wrapper = document.createElement('div');
    wrapper.className = 'ns-code-wrapper';
    const btn = document.createElement('button');
    btn.className = 'ns-copy-btn';
    btn.textContent = '复制';
    btn.addEventListener('click', () => {
      const text = codeElement.innerText || codeElement.textContent;
      GM_setClipboard(text);
      const originalText = btn.textContent;
      btn.textContent = '已复制!';
      setTimeout(() => { btn.textContent = originalText; }, 2000);
    });
    preElement.parentNode.insertBefore(wrapper, preElement);
    wrapper.appendChild(preElement);
    wrapper.appendChild(btn);
  };

  // ==========================================
  // 模块 6: 观察者
  // ==========================================
  let renderQueue = new Set();
  let renderTimer = null;
  const flushQueue = () => {
    renderQueue.forEach(node => {
      if (!document.contains(node)) return;
      if (node.classList.contains('user-card')) processUserCard(node, 0);
      else if (node.classList.contains('content-item')) processCommentItem(node);
      else if (node.classList.contains('post-list-item')) processPostListItem(node);
      else if (node.tagName === 'PRE') processCodeBlock(node);
      else if (node.classList.contains('expression')) processQuickReplyUI(node);
    });
    renderQueue.clear();
  };
  const initObserver = () => {
    document.addEventListener('animationstart', (e) => {
      if (e.animationName === 'nsNodeDetected') {
        renderQueue.add(e.target);
        if (renderTimer) cancelAnimationFrame(renderTimer);
        renderTimer = requestAnimationFrame(flushQueue);
      }
    }, true);
  };

  initStyles();
  initObserver();

})();
