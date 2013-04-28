define [
  'jquery',
  'underscore',
  'backbone',
  'raphael',
  'scale.raphael',
  'globals',
  'cs!utils',
  'cs!models/whiteboard_cursor',
  'cs!models/whiteboard_rect',
  'cs!models/whiteboard_line',
  'cs!models/whiteboard_ellipse',
  'cs!models/whiteboard_triangle',
  'cs!models/whiteboard_text'
], ($, _, Backbone, Raphael, ScaleRaphael, globals, Utils,
    WhiteboardCursorModel, WhiteboardRectModel, WhiteboardLineModel, WhiteboardEllipseModel,
    WhiteboardTriangleModel, WhiteboardTextModel) ->

  # TODO: temporary solution
  PRESENTATION_SERVER = window.location.protocol + "//" + window.location.host
  PRESENTATION_SERVER = PRESENTATION_SERVER.replace(/:\d+/, "/") # remove :port

  # "Paper" which is the Raphael term for the entire SVG object on the webpage.
  # This class deals with this SVG component only.
  WhiteboardPaperModel = Backbone.Model.extend

    # Container must be a DOM element
    initialize: (@container) ->
      # TODO: these can be replaced by variables stored inside `@currentSlide`
      @gw = "100%"
      @gh = "100%"

      # a WhiteboardCursorModel
      @cursor = null

      @slides = null
      @currentSlide = null
      @fitToPage = true

      @panX = null
      @panY = null

      # a raphaeljs set with all the shapes in the current slide
      @currentShapes = null
      # a list of shapes as passed to this client when it receives `all_slides`
      # (se we are able to redraw the shapes whenever needed)
      @currentShapesDefinitions = []
      # pointers to the current shapes being drawn
      @currentLine = null
      @currentRect = null
      @currentEllipse = null
      @currentTriangle = null
      @currentText = null

      @zoomLevel = 1
      @shiftPressed = false
      @currentPathCount = 0

      $(window).on "resize.whiteboard_paper", _.bind(@_onWindowResize, @)
      $(document).on "keydown.whiteboard_paper", _.bind(@_onKeyDown, @)
      $(document).on "keyup.whiteboard_paper", _.bind(@_onKeyUp, @)

      @_updateContainerDimensions()

    # Override the close() to unbind events.
    unbindEvents: ->
      $(window).off "resize.whiteboard_paper"
      $(document).off "keydown.whiteboard_paper"
      $(document).off "keyup.whiteboard_paper"
      # TODO: other events are being used in the code and should be off() here

    # Initializes the paper in the page.
    # Can't do these things in initialize() because by then some elements
    # are not yet created in the page.
    create: ->
      # paper is embedded within the div#slide of the page.
      @raphaelObj ?= ScaleRaphael(@container, @gw, @gh)
      @raphaelObj.canvas.setAttribute "preserveAspectRatio", "xMinYMin slice"

      @cursor = new WhiteboardCursorModel(@raphaelObj)
      @cursor.draw()
      @cursor.on "cursor:mousewheel", _.bind(@_zoomSlide, @)

      if @slides
        @rebuild()
      else
        @slides = {} # if previously loaded
      unless navigator.userAgent.indexOf("Firefox") is -1
        @raphaelObj.renderfix()

    # Re-add the images to the paper that are found
    # in the slides array (an object of urls and dimensions).
    rebuild: ->
      @_setCurrentSlide(null)
      for url of @slides
        if @slides.hasOwnProperty(url)
          @addImageToPaper url, @slides[url].w, @slides[url].h

    # A wrapper around ScaleRaphael's `changeSize()` method, more details at:
    #   http://www.shapevent.com/scaleraphael/
    # Also makes sure that the images are redraw in the canvas so they are actually resized.
    changeSize: (windowWidth, windowHeight, center=true, clipping=false) ->
      if @raphaelObj?
        @raphaelObj.changeSize(windowWidth, windowHeight, center, clipping)

        # TODO: we can scale the slides and drawings instead of re-adding them, but the logic
        #       will change quite a bit
        # slides
        slidesTmp = _.clone(@slides)
        urlTmp = @_getCurrentSlide()
        @removeAllImagesFromPaper()
        @slides = slidesTmp
        @rebuild()
        @showImageFromPaper(urlTmp.url)
        # drawings
        tmp = _.clone(@currentShapesDefinitions)
        @clearShapes()
        @drawListOfShapes(tmp)

    # Add an image to the paper.
    # @param {string} url the URL of the image to add to the paper
    # @param {number} width   the width of the image (in pixels)
    # @param {number} height   the height of the image (in pixels)
    # @return {Raphael.image} the image object added to the whiteboard
    addImageToPaper: (url, width, height) ->
      @_updateContainerDimensions()

      console.log "adding image to paper", url, width, height
      if @fitToPage
        # solve for the ratio of what length is going to fit more than the other
        max = Math.max(width / @containerWidth, height / @containerHeight)
        # fit it all in appropriately
        # TODO: temporary solution
        url = PRESENTATION_SERVER + url unless url.match(/http[s]?:/)
        sw = width / max
        sh = height / max
        cx = (@containerWidth / 2) - (width / 2)
        cy = (@containerHeight / 2) - (height / 2)
        img = @raphaelObj.image(url, cx, cy, @gw = width, @gh = height)
      else
        # fit to width
        console.log "no fit"
        # assume it will fit width ways
        sw = width / wr
        sh = height / wr
        wr = width / @containerWidth
        img = @raphaelObj.image(url, cx = 0, cy = 0, width / wr, height / wr)
        @gw = sw
        @gh = sh

      @slides[url] =
        id: img.id
        w: sw     # sw slide width as percentage of original width of paper
        h: sh     # sh slide height as a percentage of original height of paper
        img: img
        url: url
        cx: cx    # x-offset from top left corner as percentage of original width of paper
        cy: cy    # y-offset from top left corner as percentage of original height of paper

      unless @_getCurrentSlide()?
        img.toBack()
        @_setCurrentSlide(@slides[url])
      else if @_getCurrentSlide()?.url is url
        img.toBack()
      else
        img.hide()
      $(@container).on "mousemove", _.bind(@_onMouseMove, @)
      $(@container).on "mousewheel", _.bind(@_zoomSlide, @)
      # TODO $(img.node).bind "mousewheel", zoomSlide
      @trigger('paper:image:added', img)

      # TODO: other places might also required an update in these dimensions
      @_updateContainerDimensions()

      img

    # Removes all the images from the Raphael paper.
    removeAllImagesFromPaper: ->
      for url of @slides
        if @slides.hasOwnProperty(url)
          @raphaelObj.getById(@slides[url].id).remove()
          @trigger('paper:image:removed', @slides[url].id)
      @slides = {}
      @_setCurrentSlide(null)

    # Shows an image from the paper.
    # The url must be in the slides array.
    # @param  {string} url the url of the image (must be in slides array)
    showImageFromPaper: (url) ->
      url = PRESENTATION_SERVER + url unless url.match(/http[s]?:/)
      if @_getCurrentSlide()?.url isnt url and @slides[url]?
        # TODO: temporary solution
        @_hideImageFromPaper @_getCurrentSlide()?.url
        next = @_getImageFromPaper(url)
        if next
          next.show()
          next.toFront()
          @currentShapes.forEach (element) ->
            element.toFront()
          @cursor.toFront()
        @_setCurrentSlide(@slides[url])

    # Updates the paper from the server values.
    # @param  {number} cx_ the x-offset value as a percentage of the original width
    # @param  {number} cy_ the y-offset value as a percentage of the original height
    # @param  {number} sw_ the slide width value as a percentage of the original width
    # @param  {number} sh_ the slide height value as a percentage of the original height
    # TODO: not tested yet
    updatePaperFromServer: (cx_, cy_, sw_, sh_) ->
      # if updating the slide size (zooming!)
      if sw_ and sh_
        @raphaelObj.setViewBox cx_ * @gw, cy_ * @gh, sw_ * @gw, sh_ * @gh
        sw = @gw / sw_
        sh = @gh / sh_
      # just panning, so use old slide size values
      else
        [sw, sh] = @_currentSlideDimensions()
        @raphaelObj.setViewBox cx_ * @gw, cy_ * @gh, @raphaelObj._viewBox[2], @raphaelObj._viewBox[3]

      # update corners
      cx = cx_ * sw
      cy = cy_ * sh
      # update position of svg object in the window
      sx = (@containerWidth - @gw) / 2
      sy = (@containerHeight - @gh) / 2
      sy = 0  if sy < 0
      @raphaelObj.canvas.style.left = sx + "px"
      @raphaelObj.canvas.style.top = sy + "px"
      @raphaelObj.setSize @gw - 2, @gh - 2

      # update zoom level and cursor position
      z = @raphaelObj._viewBox[2] / @gw
      @zoomLevel = z
      @cursor.setRadius(dcr * z)

      # force the slice attribute despite Raphael changing it
      @raphaelObj.canvas.setAttribute "preserveAspectRatio", "xMinYMin slice"

    # Switches the tool and thus the functions that get
    # called when certain events are fired from Raphael.
    # @param  {string} tool the tool to turn on
    # @return {undefined}
    setCurrentTool: (tool) ->
      @currentTool = tool
      console.log "setting current tool to", tool
      switch tool
        when "path", "line"
          @cursor.undrag()
          @currentLine = @_createTool(tool)
          @cursor.drag(@currentLine.dragOnMove, @currentLine.dragOnStart, @currentLine.dragOnEnd)
        when "rect"
          @cursor.undrag()
          @currentRect = @_createTool(tool)
          @cursor.drag(@currentRect.dragOnMove, @currentRect.dragOnStart, @currentRect.dragOnEnd)

        # TODO: the shapes below are still in the old format
        # when "panzoom"
        #   @cursor.undrag()
        #   @cursor.drag _.bind(@_panDragging, @),
        #     _.bind(@_panGo, @), _.bind(@_panStop, @)
        # when "ellipse"
        #   @cursor.undrag()
        #   @cursor.drag _.bind(@_ellipseDragging, @),
        #     _.bind(@_ellipseDragStart, @), _.bind(@_ellipseDragStop, @)
        # when "text"
        #   @cursor.undrag()
        #   @cursor.drag _.bind(@_rectDragging, @),
        #     _.bind(@_textStart, @), _.bind(@_textStop, @)
        else
          console.log "ERROR: Cannot set invalid tool:", tool

    # Sets the fit to page.
    # @param {boolean} value If true fit to page. If false fit to width.
    # TODO: not really working as it should be
    setFitToPage: (value) ->
      @fitToPage = value

      # TODO: we can scale the slides and drawings instead of re-adding them, but the logic
      #       will change quite a bit
      temp = @slides
      @removeAllImagesFromPaper()
      @slides = temp
      # re-add all the images as they should fit differently
      @rebuild()

      # set to default zoom level
      globals.connection.emitPaperUpdate 0, 0, 1, 1
      # get the shapes to reprocess
      globals.connection.emitAllShapes()

    # Socket response - Update zoom variables and viewbox
    # @param {number} d the delta value from the scroll event
    # @return {undefined}
    setZoom: (d) ->
      step = 0.05 # step size
      if d < 0
        @zoomLevel += step # zooming out
      else
        @zoomLevel -= step # zooming in

      [sw, sh] = @_currentSlideDimensions()
      [cx, cy] = @_currentSlideOffsets()
      x = cx / sw
      y = cy / sh
      # cannot zoom out further than 100%
      z = (if @zoomLevel > 1 then 1 else @zoomLevel)
      # cannot zoom in further than 400% (1/4)
      z = (if z < 0.25 then 0.25 else z)
      # cannot zoom to make corner less than (x,y) = (0,0)
      x = (if x < 0 then 0 else x)
      y = (if y < 0 then 0 else y)
      # cannot view more than the bottom corners
      zz = 1 - z
      x = (if x > zz then zz else x)
      y = (if y > zz then zz else y)
      globals.connection.emitPaperUpdate x, y, z, z # send update to all clients

    stopPanning: ->
      # nothing to do

    # Draws an array of shapes to the paper.
    # @param  {array} shapes the array of shapes to draw
    drawListOfShapes: (shapes) ->
      @currentShapesDefinitions = shapes
      @currentShapes = @raphaelObj.set()
      for shape in shapes
        data = if _.isString(shape.data) then JSON.parse(shape.data) else shape.data
        tool = @_createTool(shape.shape)
        if tool?
          @currentShapes.push tool.draw.apply(tool, data)
        else
          console.log "shape not recognized at drawListOfShapes", shape

      # make sure the cursor is still on top
      @cursor.toFront()

    # Clear all shapes from this paper.
    clearShapes: ->
      console.log "clearing shapes"
      if @currentShapes?
        @currentShapes.forEach (element) ->
          element.remove()
        @currentShapes = null
        @currentShapesDefinitions = []

    # Updated a shape `shape` with the data in `data`.
    # TODO: check if the objects exist before calling update, if they don't they should be created
    updateShape: (shape, data) ->
      switch shape
        when "line"
          @currentLine.update.apply(@currentLine, data)
        when "rect"
          @currentRect.update.apply(@currentRect, data)
        when "ellipse"
          @currentEllipse.update.apply(@currentEllipse, data)
        when "triangle"
          @currentTriangle.update.apply(@currentTriangle, data)
        when "text"
          @currentText.update.apply(@currentText, data)
        else
          console.log "shape not recognized at updateShape", shape

    # Make a shape `shape` with the data in `data`.
    makeShape: (shape, data) ->
      tool = null
      switch shape
        when "path", "line"
          @currentLine = @_createTool(shape)
          toolModel = @currentLine
          tool = @currentLine.make.apply(@currentLine, data)
        when "rect"
          @currentRect = @_createTool(shape)
          toolModel = @currentRect
          tool = @currentRect.make.apply(@currentRect, data)
        when "ellipse"
          @currentEllipse = @_createTool(shape)
          toolModel = @currentEllipse
          tool = @currentEllipse.make.apply(@currentEllipse, data)
        when "triangle"
          @currentTriangle = @_createTool(shape)
          toolModel = @currentTriangle
          tool = @currentTriangle.make.apply(@currentTriangle, data)
        when "text"
          @currentText = @_createTool(shape)
          toolModel = @currentText
          tool = @currentText.make.apply(@currentText, data)
        else
          console.log "shape not recognized at makeShape", shape
      if tool?
        @currentShapes.push(tool)
        @currentShapesDefinitions.push(toolModel.getDefinition())

    # Update the cursor position on screen
    # @param  {number} x the x value of the cursor as a percentage of the width
    # @param  {number} y the y value of the cursor as a percentage of the height
    moveCursor: (x, y) ->
      [cx, cy] = @_currentSlideOffsets()
      @cursor.setPosition(x * @gw + cx,  y * @gh + cy)

    # Update the dimensions of the container.
    _updateContainerDimensions: ->
      $container = $(@container)
      @containerWidth = $container.innerWidth()
      @containerHeight = $container.innerHeight()
      @containerOffsetLeft = $container.offset().left
      @containerOffsetTop = $container.offset().top

    # Retrieves an image element from the paper.
    # The url must be in the slides array.
    # @param  {string} url        the url of the image (must be in slides array)
    # @return {Raphael.image}     return the image or null if not found
    _getImageFromPaper: (url) ->
      if @slides[url]
        id = @slides[url].id
        return @raphaelObj.getById(id) if id?
      null

    # Hides an image from the paper given the URL.
    # The url must be in the slides array.
    # @param  {string} url the url of the image (must be in slides array)
    _hideImageFromPaper: (url) ->
      img = @_getImageFromPaper(url)
      img.hide() if img?

    # Update zoom variables on all clients
    # @param  {Event} e the event that occurs when scrolling
    # @param  {number} delta the speed/direction at which the scroll occurred
    _zoomSlide: (e, delta) ->
      globals.connection.emitZoom delta

    # Called when the cursor is moved over the presentation.
    # Sends cursor moving event to server.
    # @param  {Event} e the mouse event
    # @param  {number} x the x value of cursor at the time in relation to the left side of the browser
    # @param  {number} y the y value of cursor at the time in relation to the top of the browser
    # TODO: this should only be done if the user is the presenter
    _onMouseMove: (e, x, y) ->
      [sw, sh] = @_currentSlideDimensions()
      xLocal = (e.pageX - @containerOffsetLeft) / sw
      yLocal = (e.pageY - @containerOffsetTop) / sh
      globals.connection.emitMoveCursor xLocal, yLocal

    # When the user is dragging the cursor (click + move)
    # @param  {number} dx the difference between the x value from panGo and now
    # @param  {number} dy the difference between the y value from panGo and now
    _panDragging: (dx, dy) ->
      sx = (@containerWidth - @gw) / 2
      sy = (@containerHeight - @gh) / 2
      [sw, sh] = @_currentSlideDimensions()

      # ensuring that we cannot pan outside of the boundaries
      x = (@panX - dx)
      # cannot pan past the left edge of the page
      x = (if x < 0 then 0 else x)
      y = (@panY - dy)
      # cannot pan past the top of the page
      y = (if y < 0 then 0 else y)
      if @fitToPage
        x2 = @gw + x
      else
        x2 = @containerWidth + x
      # cannot pan past the width
      x = (if x2 > sw then sw - (@containerWidth - sx * 2) else x)
      if @fitToPage
        y2 = @gh + y
      else
        # height of image could be greater (or less) than the box it fits in
        y2 = @containerHeight + y
      # cannot pan below the height
      y = (if y2 > sh then sh - (@containerHeight - sy * 2) else y)
      globals.connection.emitPaperUpdate x / sw, y / sh, null, null

    # When panning starts
    # @param  {number} x the x value of the cursor
    # @param  {number} y the y value of the cursor
    _panGo: (x, y) ->
      [cx, cy] = @_currentSlideOffsets()
      @panX = cx
      @panY = cy

    # When panning finishes
    # @param  {Event} e the mouse event
    _panStop: (e) ->
      @stopPanning()

    # Called when the application window is resized.
    _onWindowResize: ->
      @_updateContainerDimensions()

    # when pressing down on a key at anytime
    _onKeyDown: (event) ->
      unless event
        keyCode = window.event.keyCode
      else
        keyCode = event.keyCode
      switch keyCode
        when 16 # shift key
          @shiftPressed = true

    # when releasing any key at any time
    _onKeyUp: ->
      unless event
        keyCode = window.event.keyCode
      else
        keyCode = event.keyCode
      switch keyCode
        when 16 # shift key
          @shiftPressed = false

    _setCurrentSlide: (value) ->
      @currentSlide = value

    _getCurrentSlide: ->
      @currentSlide

    _currentSlideDimensions: ->
      if @currentSlide?
        [ @currentSlide.w or 0,
          @currentSlide.h or 0 ]
      else
        [0, 0]

    _currentSlideOffsets: ->
      if @currentSlide?
        [ @currentSlide.cx or 0,
          @currentSlide.cy or 0 ]
      else
        [0, 0]

    # Wrapper method to create a tool for the whiteboard
    _createTool: (type) ->
      switch type
        when "path", "line"
          model = WhiteboardLineModel
        when "rect"
          model = WhiteboardRectModel
        when "ellipse"
          model = WhiteboardEllipseModel
        when "triangle"
          model = WhiteboardTriangleModel
        when "text"
          model = WhiteboardTextModel

      if model?
        tool = new model(@raphaelObj)
        tool.setPaperSize(@gh, @gw)
        tool.setOffsets.apply(tool, @_currentSlideOffsets())
        tool.setPaperDimensions.apply(tool, @_currentSlideDimensions())
        tool
      else
        null

  WhiteboardPaperModel
