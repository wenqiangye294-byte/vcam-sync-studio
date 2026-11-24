(() => {
  const state = {
    full: null,
    search: "",
    modalMode: "create", // 'create' | 'rename'
    editingProductId: null,
    dragKind: null,
    dragId: null,
    ws: null,
  };

  const $ = (id) => document.getElementById(id);

  function escapeHtml(text) {
    return String(text ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function showToast(msg, isError = false) {
    const stack = $("toastStack");
    const el = document.createElement("div");
    el.className = "toast" + (isError ? " error" : "");
    el.textContent = msg;
    stack.appendChild(el);
    setTimeout(() => {
      el.remove();
    }, 3200);
  }

  async function apiFetch(url, options = {}) {
    const resp = await fetch(url, options);
    const data = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      throw new Error(data.detail || `请求失败 (${resp.status})`);
    }
    return data;
  }

  function formatTime(ts) {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    return d.toLocaleTimeString("zh-CN", { hour12: false });
  }

  function formatSize(bytes) {
    if (!bytes) return "0 KB";
    if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }

  function renderAll() {
    if (!state.full) return;
    const { manifest, config, products, devices, events, network } = state.full;
    const activeProd = manifest.product;

    // Header
    $("revBadge").textContent = `v${manifest.revision}`;
    const enabled = Boolean(config.enabled);
    $("masterEnableBtn").classList.toggle("active", enabled);
    $("masterEnableText").textContent = enabled ? "虚拟相机：已启用" : "虚拟相机：已暂停";

    // Active banner
    $("activeProductTitle").textContent = activeProd.name;
    const photoTotal = activeProd.photos.length;
    const videoTotal = activeProd.videos.length;
    const photoStepText = photoTotal > 0 ? `第 ${activeProd.photo_cursor + 1} / ${photoTotal} 张` : "暂无图片";
    const videoStepText = videoTotal > 0 ? `第 ${activeProd.video_cursor + 1} / ${videoTotal} 个` : "暂无视频";
    $("activeSummary").textContent = `拍照队列：${photoStepText} · 长按录制视频：${videoStepText}${activeProd.note ? ` · ${activeProd.note}` : ""}`;

    // Products list
    renderProducts(products, activeProd.id);

    // Media queues
    $("photoCountPill").textContent = `${photoTotal} 张`;
    $("videoCountPill").textContent = `${videoTotal} 个`;
    renderMediaGrid("photo", activeProd.photos, activeProd.photo_cursor);
    renderMediaGrid("video", activeProd.videos, activeProd.video_cursor);

    // Settings
    $("loopPhotosChk").checked = Boolean(config.loop_photos);
    $("loopVideosChk").checked = Boolean(config.loop_videos);
    $("videoModeSelect").value = config.video_replace_mode || "full";
    $("fillModeSelect").value = config.fill_mode || "fill";
    $("rotationSelect").value = String(config.rotation ?? 0);
    $("mirrorChk").checked = Boolean(config.mirror);
    $("showHudChk").checked = Boolean(config.show_hud);

    // Network & QR
    renderNetwork(network);
    renderDevices(devices);
    renderEvents(events);
  }

  function renderProducts(products, activeId) {
    const listEl = $("productList");
    const q = state.search.trim().toLowerCase();
    const filtered = products.filter((p) => !q || p.name.toLowerCase().includes(q));
    if (filtered.length === 0) {
      listEl.innerHTML = `<div class="empty-hint">没有匹配的商品包</div>`;
      return;
    }

    listEl.innerHTML = filtered
      .map((p) => {
        const isActive = p.id === activeId;
        return `
          <div class="product-item ${isActive ? "active" : ""}" data-pid="${escapeHtml(p.id)}">
            <div class="product-item-top">
              <div class="product-item-name" title="${escapeHtml(p.name)}">${escapeHtml(p.name)}</div>
              ${isActive ? `<span class="product-active-tag">当前同步</span>` : ""}
            </div>
            <div class="product-item-meta">
              <span>图 ${p.photo_count} · 视 ${p.video_count}</span>
              <div class="product-item-ops">
                <button type="button" class="icon-mini-btn" data-action="rename" data-pid="${escapeHtml(p.id)}">改名</button>
                <button type="button" class="icon-mini-btn danger" data-action="delete" data-pid="${escapeHtml(p.id)}">删除</button>
              </div>
            </div>
          </div>
        `;
      })
      .join("");
  }

  function renderMediaGrid(kind, items, cursor) {
    const gridEl = $(kind === "photo" ? "photoGrid" : "videoGrid");
    if (!items || items.length === 0) {
      gridEl.innerHTML = `<div class="empty-hint" style="grid-column: 1 / -1;">${
        kind === "photo"
          ? "暂无拍照图片。拖拽图片到此，或从左侧批量导入本地文件夹。"
          : "暂无长按录制视频。上传 .mp4 / .mov 后，手机长按录制即可自动替换。"
      }</div>`;
      return;
    }

    gridEl.innerHTML = items
      .map((item, idx) => {
        const isCur = idx === cursor;
        const previewHtml =
          kind === "photo"
            ? `<img src="${escapeHtml(item.thumb_url || item.url)}" loading="lazy" alt="${escapeHtml(item.original_name)}" />`
            : `<video src="${escapeHtml(item.url)}#t=0.1" muted preload="metadata"></video>`;
        const metaText =
          kind === "photo"
            ? `${item.width || "?"}×${item.height || "?"} · ${formatSize(item.size)}`
            : `${item.duration ? item.duration.toFixed(1) + "s · " : ""}${
                item.width ? `${item.width}×${item.height} · ` : ""
              }${formatSize(item.size)}`;

        return `
          <div class="media-card ${isCur ? "is-current" : ""}" draggable="true" data-kind="${kind}" data-id="${escapeHtml(item.id)}" data-index="${idx}">
            <div class="media-thumb-box" data-preview-kind="${kind}" data-url="${escapeHtml(item.url)}" data-title="${escapeHtml(item.original_name)}">
              ${previewHtml}
              <span class="order-badge">#${idx + 1}</span>
              ${isCur ? `<span class="current-badge">${kind === "photo" ? "下一张待拍" : "当前视频"}</span>` : ""}
            </div>
            <div class="media-card-body">
              <div class="media-name" title="${escapeHtml(item.original_name)}">${escapeHtml(item.original_name)}</div>
              <div class="media-meta">${escapeHtml(metaText)}</div>
              <div class="media-actions">
                <button type="button" class="btn-inline" data-set-cursor="${kind}" data-index="${idx}">
                  ${isCur ? "当前选中" : "设为当前"}
                </button>
                <div class="media-move-group">
                  <button type="button" class="icon-mini-btn" data-move="${kind}" data-dir="-1" data-index="${idx}" title="前移">←</button>
                  <button type="button" class="icon-mini-btn" data-move="${kind}" data-dir="1" data-index="${idx}" title="后移">→</button>
                  <button type="button" class="icon-mini-btn danger" data-del-media="${escapeHtml(item.id)}" title="移除">删</button>
                </div>
              </div>
            </div>
          </div>
        `;
      })
      .join("");
  }

  function renderNetwork(network) {
    if (!network) return;
    const select = $("hostSelect");
    const ips = network.lan_ips || [];
    select.innerHTML = ips
      .map(
        (entry) =>
          `<option value="${escapeHtml(entry.ip)}" ${
            entry.ip === network.active_host ? "selected" : ""
          }>${escapeHtml(entry.label)}</option>`
      )
      .join("");

    $("qrSvgWrap").innerHTML = network.qr_svg || "";
    $("pairUrlInput").value = network.pair_url || "";
    const discBadge = $("discoveryBadge");
    if (network.discovery_active) {
      discBadge.textContent = `UDP 自动发现已开启 (:${network.discovery_port})`;
      discBadge.classList.remove("warn");
    } else {
      discBadge.textContent = `UDP 端口未监听，请直接扫码配对`;
      discBadge.classList.add("warn");
    }
  }

  function renderDevices(devices) {
    const listEl = $("deviceList");
    const onlineCount = (devices || []).filter((d) => d.connected).length;
    $("deviceCountPill").textContent = `${onlineCount} 台在线`;

    if (!devices || devices.length === 0) {
      listEl.innerHTML = `<div class="empty-hint">暂无手机连接。请在 iPhone 打开 <strong>VCamSync</strong> 扫码或点击「搜索局域网电脑」。</div>`;
      return;
    }

    listEl.innerHTML = devices
      .map((d) => {
        const apps = Array.isArray(d.target_apps) && d.target_apps.length
          ? d.target_apps.map((a) => (typeof a === "string" ? a : a.name || a.bundle_id)).join("、")
          : "未选择（如已越狱可全局生效）";
        return `
          <div class="device-card">
            <div class="device-top">
              <div class="device-name">
                <span class="status-dot ${d.connected ? "online" : ""}"></span>
                <span>${escapeHtml(d.device_name || "iPhone")}</span>
              </div>
              <span class="count-pill">${d.connected ? "在线" : "离线"} · v${d.sync_revision || 0}</span>
            </div>
            <div class="device-sub">
              iOS ${escapeHtml(d.ios_version || "16.2")} · ${escapeHtml(d.ip || "-")}<br/>
              同步状态：${escapeHtml(d.sync_status || "idle")}<br/>
              目标 App：${escapeHtml(apps)}
            </div>
          </div>
        `;
      })
      .join("");
  }

  function renderEvents(events) {
    const listEl = $("eventList");
    if (!events || events.length === 0) {
      listEl.innerHTML = `<div class="empty-hint">暂无动态</div>`;
      return;
    }
    listEl.innerHTML = events
      .slice(0, 30)
      .map(
        (ev) => `
          <div class="event-item ${escapeHtml(ev.source)}">
            <div class="event-head">
              <span>${ev.source === "ios" ? "iPhone 端" : "电脑端"}</span>
              <span>${escapeHtml(formatTime(ev.ts))}</span>
            </div>
            <div>${escapeHtml(ev.message)}</div>
          </div>
        `
      )
      .join("");
  }

  async function refreshState() {
    try {
      state.full = await apiFetch("/api/queue/state");
      renderAll();
    } catch (err) {
      showToast(err.message, true);
    }
  }

  function connectUIWebSocket() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(`${proto}//${location.host}/ws/ui`);
    state.ws = ws;

    ws.onopen = () => {
      $("uiWsPill").classList.add("online");
      $("uiWsText").textContent = "实时同步已连接";
    };

    ws.onmessage = (evt) => {
      try {
        const msg = JSON.parse(evt.data);
        if (msg.event === "state_updated" && msg.state) {
          state.full = msg.state;
          renderAll();
        }
      } catch {}
    };

    ws.onclose = () => {
      $("uiWsPill").classList.remove("online");
      $("uiWsText").textContent = "重连中...";
      setTimeout(connectUIWebSocket, 2000);
    };
  }

  async function patchSettings(patch) {
    try {
      state.full = await apiFetch("/api/queue/settings", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch),
      });
      renderAll();
    } catch (err) {
      showToast(err.message, true);
    }
  }

  async function stepQueue(kind, delta, reset = false) {
    try {
      state.full = await apiFetch("/api/queue/step", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind, delta, reset }),
      });
      renderAll();
    } catch (err) {
      showToast(err.message, true);
    }
  }

  async function uploadFiles(fileList) {
    if (!state.full || !fileList || fileList.length === 0) return;
    const pid = state.full.manifest.product.id;
    const formData = new FormData();
    for (const f of fileList) {
      formData.append("files", f);
    }
    try {
      const res = await apiFetch(`/api/products/${encodeURIComponent(pid)}/media`, {
        method: "POST",
        body: formData,
      });
      if (res.state) {
        state.full = res.state;
        renderAll();
      }
      const addedCount = (res.added || []).length;
      const skippedCount = (res.skipped || []).length;
      showToast(
        `已上传 ${addedCount} 个素材${skippedCount ? `（跳过 ${skippedCount} 个不支持格式）` : ""}`
      );
    } catch (err) {
      showToast(err.message, true);
    }
  }

  async function reorderBySwap(kind, fromIdx, toIdx) {
    const prod = state.full.manifest.product;
    const items = kind === "photo" ? [...prod.photos] : [...prod.videos];
    if (toIdx < 0 || toIdx >= items.length || fromIdx === toIdx) return;
    const [moved] = items.splice(fromIdx, 1);
    items.splice(toIdx, 0, moved);
    const orderedIds = items.map((x) => x.id);
    try {
      const res = await apiFetch(`/api/products/${encodeURIComponent(prod.id)}/reorder`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind, ordered_ids: orderedIds }),
      });
      if (res.state) {
        state.full = res.state;
        renderAll();
      }
    } catch (err) {
      showToast(err.message, true);
    }
  }

  function openProductModal(mode, productId = null) {
    state.modalMode = mode;
    state.editingProductId = productId;
    if (mode === "rename" && state.full) {
      const target = (state.full.products || []).find((p) => p.id === productId);
      $("productModalTitle").textContent = "编辑商品包";
      $("productNameInput").value = target ? target.name : "";
      $("productNoteInput").value = target ? target.note || "" : "";
    } else {
      $("productModalTitle").textContent = "新建商品任务包";
      $("productNameInput").value = "";
      $("productNoteInput").value = "";
    }
    $("productModal").classList.remove("hidden");
    $("productNameInput").focus();
  }

  function closeProductModal() {
    $("productModal").classList.add("hidden");
  }

  function setupDropzone(el) {
    el.addEventListener("dragover", (e) => {
      e.preventDefault();
      el.classList.add("drag-over");
    });
    el.addEventListener("dragleave", () => el.classList.remove("drag-over"));
    el.addEventListener("drop", (e) => {
      e.preventDefault();
      el.classList.remove("drag-over");
      if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) {
        uploadFiles(e.dataTransfer.files);
      }
    });
  }

  function setupEvents() {
    $("masterEnableBtn").addEventListener("click", () => {
      if (!state.full) return;
      patchSettings({ enabled: !state.full.config.enabled });
    });

    $("pushSyncBtn").addEventListener("click", async () => {
      try {
        const res = await apiFetch("/api/queue/push", { method: "POST" });
        if (res.state) {
          state.full = res.state;
          renderAll();
        }
        showToast("已推送最新版本到已连接的 iPhone");
      } catch (err) {
        showToast(err.message, true);
      }
    });

    $("shutdownBtn").addEventListener("click", async () => {
      if (!confirm("确认关闭后台服务并退出桌面工作台？")) return;
      try {
        await apiFetch("/api/system/shutdown", { method: "POST" });
        showToast("服务正在关闭，可安全关闭窗口");
        setTimeout(() => window.close(), 500);
      } catch (err) {
        showToast(err.message, true);
      }
    });

    $("guideBtn").addEventListener("click", () => $("guideModal").classList.remove("hidden"));
    $("closeGuideModalBtn").addEventListener("click", () => $("guideModal").classList.add("hidden"));
    $("guideModal").addEventListener("click", (e) => {
      if (e.target === $("guideModal")) $("guideModal").classList.add("hidden");
    });

    // Product actions
    $("newProductBtn").addEventListener("click", () => openProductModal("create"));
    $("renameActiveBtn").addEventListener("click", () => {
      if (state.full) openProductModal("rename", state.full.manifest.product.id);
    });
    $("closeProductModalBtn").addEventListener("click", closeProductModal);
    $("cancelProductModalBtn").addEventListener("click", closeProductModal);

    $("saveProductModalBtn").addEventListener("click", async () => {
      const name = $("productNameInput").value.trim();
      const note = $("productNoteInput").value.trim();
      if (!name) {
        showToast("请输入商品名称", true);
        return;
      }
      try {
        if (state.modalMode === "rename" && state.editingProductId) {
          const res = await apiFetch(
            `/api/products/${encodeURIComponent(state.editingProductId)}`,
            {
              method: "PATCH",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ name, note }),
            }
          );
          if (res.state) state.full = res.state;
          showToast("商品信息已更新");
        } else {
          const res = await apiFetch("/api/products", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name, note, activate: true }),
          });
          if (res.state) state.full = res.state;
          showToast("已新建并切换到该商品包");
        }
        renderAll();
        closeProductModal();
      } catch (err) {
        showToast(err.message, true);
      }
    });

    $("productSearchInput").addEventListener("input", (e) => {
      state.search = e.target.value;
      if (state.full) renderProducts(state.full.products, state.full.manifest.product.id);
    });

    $("productList").addEventListener("click", async (e) => {
      const btn = e.target.closest("button[data-action]");
      if (btn) {
        e.stopPropagation();
        const pid = btn.dataset.pid;
        const action = btn.dataset.action;
        if (action === "rename") {
          openProductModal("rename", pid);
        } else if (action === "delete") {
          if (!confirm("确定删除该商品包及其内部所有素材？")) return;
          try {
            const res = await apiFetch(`/api/products/${encodeURIComponent(pid)}`, {
              method: "DELETE",
            });
            if (res.state) {
              state.full = res.state;
              renderAll();
            }
            showToast("商品包已删除");
          } catch (err) {
            showToast(err.message, true);
          }
        }
        return;
      }

      const card = e.target.closest(".product-item[data-pid]");
      if (!card) return;
      const pid = card.dataset.pid;
      try {
        const res = await apiFetch(`/api/products/${encodeURIComponent(pid)}/activate`, {
          method: "POST",
        });
        if (res.state) {
          state.full = res.state;
          renderAll();
        }
      } catch (err) {
        showToast(err.message, true);
      }
    });

    $("importFolderBtn").addEventListener("click", async () => {
      if (!state.full) return;
      const folderPath = $("folderPathInput").value.trim();
      if (!folderPath) {
        showToast("请粘贴或输入本地文件夹路径", true);
        return;
      }
      const pid = state.full.manifest.product.id;
      try {
        const res = await apiFetch(
          `/api/products/${encodeURIComponent(pid)}/import-folder`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              folder_path: folderPath,
              recursive: $("folderRecursiveChk").checked,
            }),
          }
        );
        if (res.state) {
          state.full = res.state;
          renderAll();
        }
        showToast(`成功导入 ${(res.added || []).length} 个素材`);
      } catch (err) {
        showToast(err.message, true);
      }
    });

    // Uploads
    const triggerFileInput = (accept) => {
      const input = $("mediaFileInput");
      input.accept = accept;
      input.value = "";
      input.click();
    };
    $("uploadAnyBtn").addEventListener("click", () =>
      triggerFileInput("image/*,video/mp4,video/quicktime,.mov,.mp4,.m4v")
    );
    $("pickPhotosBtn").addEventListener("click", () => triggerFileInput("image/*"));
    $("pickVideosBtn").addEventListener("click", () =>
      triggerFileInput("video/mp4,video/quicktime,.mov,.mp4,.m4v")
    );
    $("mediaFileInput").addEventListener("change", (e) => uploadFiles(e.target.files));

    setupDropzone($("photoDropzone"));
    setupDropzone($("videoDropzone"));

    // Queue step buttons
    $("prevPhotoBtn").addEventListener("click", () => stepQueue("photo", -1));
    $("nextPhotoBtn").addEventListener("click", () => stepQueue("photo", 1));
    $("resetPhotoBtn").addEventListener("click", () => stepQueue("photo", 0, true));
    $("prevVideoBtn").addEventListener("click", () => stepQueue("video", -1));
    $("nextVideoBtn").addEventListener("click", () => stepQueue("video", 1));

    // Settings changes
    $("loopPhotosChk").addEventListener("change", (e) =>
      patchSettings({ loop_photos: e.target.checked })
    );
    $("loopVideosChk").addEventListener("change", (e) =>
      patchSettings({ loop_videos: e.target.checked })
    );
    $("videoModeSelect").addEventListener("change", (e) =>
      patchSettings({ video_replace_mode: e.target.value })
    );
    $("fillModeSelect").addEventListener("change", (e) =>
      patchSettings({ fill_mode: e.target.value })
    );
    $("rotationSelect").addEventListener("change", (e) =>
      patchSettings({ rotation: Number(e.target.value) })
    );
    $("mirrorChk").addEventListener("change", (e) =>
      patchSettings({ mirror: e.target.checked })
    );
    $("showHudChk").addEventListener("change", (e) =>
      patchSettings({ show_hud: e.target.checked })
    );

    // Media grid interactions & drag reorder
    for (const gridId of ["photoGrid", "videoGrid"]) {
      const grid = $(gridId);
      grid.addEventListener("click", async (e) => {
        const setBtn = e.target.closest("[data-set-cursor]");
        if (setBtn) {
          const kind = setBtn.dataset.setCursor;
          const idx = Number(setBtn.dataset.index);
          patchSettings(kind === "photo" ? { photo_cursor: idx } : { video_cursor: idx });
          return;
        }
        const moveBtn = e.target.closest("[data-move]");
        if (moveBtn) {
          const kind = moveBtn.dataset.move;
          const idx = Number(moveBtn.dataset.index);
          const dir = Number(moveBtn.dataset.dir);
          reorderBySwap(kind, idx, idx + dir);
          return;
        }
        const delBtn = e.target.closest("[data-del-media]");
        if (delBtn) {
          const mid = delBtn.dataset.delMedia;
          try {
            const res = await apiFetch(`/api/media/${encodeURIComponent(mid)}`, {
              method: "DELETE",
            });
            if (res.state) {
              state.full = res.state;
              renderAll();
            }
          } catch (err) {
            showToast(err.message, true);
          }
          return;
        }
        const thumbBox = e.target.closest("[data-preview-kind]");
        if (thumbBox) {
          const pKind = thumbBox.dataset.previewKind;
          const url = thumbBox.dataset.url;
          $("previewTitle").textContent = thumbBox.dataset.title || "素材预览";
          $("previewBody").innerHTML =
            pKind === "photo"
              ? `<img src="${escapeHtml(url)}" alt="preview" />`
              : `<video src="${escapeHtml(url)}" controls autoplay playsinline></video>`;
          $("previewModal").classList.remove("hidden");
        }
      });

      grid.addEventListener("dragstart", (e) => {
        const card = e.target.closest(".media-card");
        if (!card) return;
        state.dragKind = card.dataset.kind;
        state.dragId = card.dataset.id;
        card.classList.add("dragging");
      });

      grid.addEventListener("dragend", () => {
        state.dragKind = null;
        state.dragId = null;
        grid.querySelectorAll(".media-card").forEach((el) => {
          el.classList.remove("dragging", "drag-target");
        });
      });

      grid.addEventListener("dragover", (e) => {
        const card = e.target.closest(".media-card");
        if (!card || card.dataset.kind !== state.dragKind) return;
        e.preventDefault();
        card.classList.add("drag-target");
      });

      grid.addEventListener("dragleave", (e) => {
        const card = e.target.closest(".media-card");
        if (card) card.classList.remove("drag-target");
      });

      grid.addEventListener("drop", async (e) => {
        const card = e.target.closest(".media-card");
        if (!card || !state.dragId || card.dataset.kind !== state.dragKind) return;
        e.preventDefault();
        card.classList.remove("drag-target");
        const targetId = card.dataset.id;
        if (targetId === state.dragId) return;

        const prod = state.full.manifest.product;
        const list = state.dragKind === "photo" ? [...prod.photos] : [...prod.videos];
        const fromIdx = list.findIndex((x) => x.id === state.dragId);
        const toIdx = list.findIndex((x) => x.id === targetId);
        if (fromIdx >= 0 && toIdx >= 0) {
          await reorderBySwap(state.dragKind, fromIdx, toIdx);
        }
      });
    }

    $("closePreviewModalBtn").addEventListener("click", () => {
      $("previewModal").classList.add("hidden");
      $("previewBody").innerHTML = "";
    });
    $("previewModal").addEventListener("click", (e) => {
      if (e.target === $("previewModal")) {
        $("previewModal").classList.add("hidden");
        $("previewBody").innerHTML = "";
      }
    });

    // Network controls
    $("hostSelect").addEventListener("change", async (e) => {
      try {
        const net = await apiFetch("/api/network/host", {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ host: e.target.value }),
        });
        if (state.full) {
          state.full.network = net;
          renderNetwork(net);
        }
        showToast("已切换局域网二维码 IP");
      } catch (err) {
        showToast(err.message, true);
      }
    });

    $("regenTokenBtn").addEventListener("click", async () => {
      try {
        const net = await apiFetch("/api/network/regenerate-token", {
          method: "POST",
        });
        if (state.full) {
          state.full.network = net;
          renderNetwork(net);
        }
        showToast("配对密钥已刷新，请手机端重新扫码");
      } catch (err) {
        showToast(err.message, true);
      }
    });

    $("copyPairUrlBtn").addEventListener("click", async () => {
      const val = $("pairUrlInput").value;
      try {
        await navigator.clipboard.writeText(val);
        showToast("已复制配对链接");
      } catch {
        $("pairUrlInput").select();
        document.execCommand("copy");
        showToast("已复制配对链接");
      }
    });
  }

  setupEvents();
  refreshState();
  connectUIWebSocket();
})();
