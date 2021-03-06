path = require 'path'

{$, $$$, ScrollView} = require 'atom'
_ = require 'underscore-plus'
fs = require 'fs-plus'
mustache = require 'mustache'
renderer = require './renderer'
markdownDirectory = atom.packages.resolvePackagePath('markdown-preview')
{File} = require path.join(markdownDirectory, '..', 'pathwatcher')

module.exports =
class AsciiDocPreviewView extends ScrollView
  atom.deserializers.add(this)

  @deserialize: (state) ->
    new AsciiDocPreviewView(state)

  @content: ->
    @div class: 'asciidoc-preview native-key-bindings', tabindex: -1

  constructor: ({@editorId, filePath}) ->
    super

    if @editorId?
      @resolveEditor(@editorId)
    else
      if atom.workspace?
        @subscribeToFilePath(filePath)
      else
        @subscribe atom.packages.once 'activated', =>
          @subscribeToFilePath(filePath)

  serialize: ->
    deserializer: 'AsciiDocPreviewView'
    filePath: @getPath()
    editorId: @editorId

  destroy: ->
    @unsubscribe()

  subscribeToFilePath: (filePath) ->
    @file = new File(filePath)
    @trigger 'title-changed'
    @handleEvents()
    @renderAsciiDoc()

  resolveEditor: (editorId) ->
    resolve = =>
      @editor = @editorForId(editorId)

      if @editor?
        @trigger 'title-changed' if @editor?
        @handleEvents()
      else
        # The editor this preview was created for has been closed so close
        # this preview since a preview cannot be rendered without an editor
        @parents('.pane').view()?.destroyItem(this)

    if atom.workspace?
      resolve()
    else
      @subscribe atom.packages.once 'activated', =>
        resolve()
        @renderAsciiDoc()

  editorForId: (editorId) ->
    for editor in atom.workspace.getEditors()
      return editor if editor.id?.toString() is editorId.toString()
    null

  handleEvents: ->
    @subscribe atom.syntax, 'grammar-added grammar-updated', _.debounce((=> @renderAsciiDoc()), 250)
    @subscribe this, 'core:move-up', => @scrollUp()
    @subscribe this, 'core:move-down', => @scrollDown()
    @subscribe this, 'core:save-as', =>
      @saveAs()
      false

    @subscribe this, 'core:copy', =>
      return false if @copyToClipboard()

    @subscribeToCommand atom.workspaceView, 'asciidoc-preview:zoom-in', =>
      zoomLevel = parseFloat(@css('zoom')) or 1
      @css('zoom', zoomLevel + .1)

    @subscribeToCommand atom.workspaceView, 'asciidoc-preview:zoom-out', =>
      zoomLevel = parseFloat(@css('zoom')) or 1
      @css('zoom', zoomLevel - .1)

    @subscribeToCommand atom.workspaceView, 'asciidoc-preview:reset-zoom', =>
      @css('zoom', 1)

    changeHandler = =>
      @renderAsciiDoc()
      pane = atom.workspace.paneForUri(@getUri())
      if pane? and pane isnt atom.workspace.getActivePane()
        pane.activateItem(this)

    renderOnChange = =>
      saveOnly = atom.config.get('asciidoc-preview.renderOnSaveOnly')
      changeHandler() if !saveOnly

    if @file?
      @subscribe(@file, 'contents-changed', changeHandler)
    else if @editor?
      @subscribe(@editor.getBuffer(), 'contents-modified', renderOnChange)
      @subscribe(@editor.getBuffer(), 'saved', changeHandler)
      @subscribe @editor, 'path-changed', => @trigger 'title-changed'

    @subscribe atom.config.observe 'asciidoc-preview.showTitle', callNow: false, changeHandler
    @subscribe atom.config.observe 'asciidoc-preview.compatMode', callNow: false, changeHandler
    @subscribe atom.config.observe 'asciidoc-preview.safeMode', callNow: false, changeHandler
    @subscribe atom.config.observe 'asciidoc-preview.defaultAttributes', callNow: false, changeHandler
    @subscribe atom.config.observe 'asciidoc-preview.showToc', callNow: false, changeHandler
    @subscribe atom.config.observe 'asciidoc-preview.showNumberedHeadings', callNow: false, changeHandler

  renderAsciiDoc: ->
    @showLoading()
    if @file?
      @file.read().then (contents) => @renderAsciiDocText(contents)
    else if @editor?
      @renderAsciiDocText(@editor.getText())

  renderAsciiDocText: (text) ->
    renderer.toHtml text, @getPath(), (html) =>
      @loading = false
      @html(html)
      @enableAnchorScroll html, (top) =>
        @scrollTop top
      @trigger('asciidoc-preview:asciidoc-changed')

  enableAnchorScroll: (html, callback) ->
    html = $(html)
    for linkElement in html.find("a")
      link = $(linkElement)
      if hrefLink = link.attr('href')
        do(hrefLink) ->
          link.on 'mouseover', (e) ->
            # TODO Use constant
            cropUrl = if (hrefLink.length > 100) then hrefLink.substr(0, 97).concat('...')  else hrefLink
            atom.workspaceView.statusBar?.prependRight("<span id='linkUrl'>#{cropUrl}<span>")
          link.on 'mouseleave', (e) ->
            $('#linkUrl').remove()
        continue if not hrefLink.match(/^#/)
        if target = $(hrefLink)
          continue if not target.offset()
          # TODO Use tab height variable instead of 43
          top = target.offset().top - 43
          do (top) ->
            link.on 'click', (e) ->
              top = top
              callback top

  getTitle: ->
    if @file?
      "#{path.basename(@getPath())} Preview"
    else if @editor?
      "#{@editor.getTitle()} Preview"
    else
      "AsciiDoc Preview"

  getIconName: ->
    "eye"

  getUri: ->
    if @file?
      "asciidoc-preview://#{@getPath()}"
    else
      "asciidoc-preview://editor/#{@editorId}"

  getPath: ->
    if @file?
      @file.getPath()
    else if @editor?
      @editor.getPath()

  showError: (result) ->
    failureMessage = result?.message

    @html $$$ ->
      @h2 'Previewing AsciiDoc Failed'
      @h3 failureMessage if failureMessage?

  showLoading: ->
    @loading = true
    if !@firstloadingdone?
      @firstloadingdone = true
      @html $$$ ->
        @div class: 'asciidoc-spinner', 'Loading AsciiDoc\u2026'

  copyToClipboard: ->
    return false if @loading

    selection = window.getSelection()
    selectedText = selection.toString()
    selectedNode = selection.baseNode

    # Use default copy event handler if there is selected text inside this view
    return false if selectedText and selectedNode? and $.contains(@[0], selectedNode)

    atom.clipboard.write(@[0].innerHTML)
    true

  saveAs: ->
    return if @loading

    filePath = @getPath()
    if filePath
      filePath += '.html'
    else
      filePath = 'untitled.adoc.html'
      if projectPath = atom.project.getPath()
        filePath = path.join(projectPath, filePath)

    if htmlFilePath = atom.showSaveDialogSync(filePath)
      mustacheObject =
        title: 'test'
        content: @[0].innerHTML

      templatePath = path.join atom.packages.resolvePackagePath('asciidoc-preview'), 'templates', 'default.html'
      page = fs.readFileSync(templatePath, 'utf8')
      htmlContent = mustache.to_html page, mustacheObject
      fs.writeFileSync(htmlFilePath, htmlContent)
      atom.workspace.open(htmlFilePath)
