'*
'* Loads data from a section in pages, distributing the results across rows of
'* a fixed size.
'*

Function createChunkedLoader(item, rowSize)
    loader = CreateObject("roAssociativeArray")
    initDataLoader(loader)

    loader.server = item.server
    loader.sourceUrl = item.sourceUrl
    loader.key = item.key + "/all"
    loader.rowSize = rowSize

    loader.masterContent = []
    loader.rowContent = []

    loader.LoadMoreContent = chunkedLoadMoreContent
    loader.GetLoadStatus = chunkedGetLoadStatus
    loader.GetPendingRequestCount = chunkedGetPendingRequestCount
    loader.RefreshData = chunkedRefreshData

    loader.StartRequest = chunkedStartRequest
    loader.OnUrlEvent = chunkedOnUrlEvent

    loader.totalSize = 0
    loader.loadedSize = 0
    loader.hasStartedLoading = false

    loader.FilterOptions = createFilterOptions(item)

    loader.SetupRows = chunkedSetupRows
    loader.SetupRows()

    ' Add a dummy item for bringing up the filters screen.
    filters = CreateObject("roAssociativeArray")
    filters.server = item.server
    filters.sourceUrl = FullUrl(item.server.serverUrl, item.sourceUrl, item.key)
    filters.ContentType = "filters"
    filters.Key = "_filters_"
    filters.Title = "Filters"
    filters.SectionType = item.ContentType
    filters.ShortDescriptionLine1 = "Filters"
    filters.Description = "Filter content in this section"
    filters.SDPosterURL = "file://pkg:/images/gear.png"
    filters.HDPosterURL = "file://pkg:/images/gear.png"
    filters.FilterOptions = loader.FilterOptions
    loader.rowContent[0].Push(filters)

    ' Make a blocking request to load the container in order to populate the
    ' first row with things like On Deck and Search.
    container = createPlexContainerForUrl(item.server, item.sourceUrl, item.key)
    container.SeparateSearchItems = true

    if m.MiscShortcutKeys = invalid then
        m.MiscShortcutKeys = CreateObject("roAssociativeArray")
        m.MiscShortcutKeys["onDeck"] = true
        m.MiscShortcutKeys["folder"] = true
    end if

    for each node in container.GetMetadata()
        if m.MiscShortcutKeys.DoesExist(node.key) then
            loader.rowContent[0].Push(node)
        end if
    next

    loader.rowContent[0].Append(container.GetSearch())

    return loader
End Function

Sub chunkedSetupRows()
    m.totalSize = 0
    m.loadedSize = 0

    ' Make a blocking request to figure out the total item count and initialize
    ' our arrays.
    request = m.server.CreateRequest(m.sourceUrl, m.FilterOptions.GetUrl())
    request.AddHeader("X-Plex-Container-Start", "0")
    request.AddHeader("X-Plex-Container-Size", "0")
    response = GetToStringWithTimeout(request, 60)
    xml = CreateObject("roXMLElement")
    if xml.parse(response) then
        m.totalSize = firstOf(xml@totalSize, "0").toInt()
    end if

    firstRowContent = firstOf(m.rowContent[0], [])
    m.names.Clear()
    m.rowContent.Clear()
    m.masterContent.Clear()
    m.names.Push("Misc")
    m.rowContent[0] = firstRowContent

    if m.totalSize > 0 then
        numRows% = ((m.totalSize - 1) / m.rowSize) + 1

        for i = 0 to numRows% - 1
            m.names.Push(tostr(i * m.rowSize + 1) + " - " + tostr((i + 1) * m.rowSize))
            m.rowContent[i + 1] = []
        next
    else
        m.names.Push("No items found")
        m.rowContent[1] = []
    end if
End Sub

Function chunkedLoadMoreContent(focusedIndex, extraRows=0) As Boolean
    if NOT m.hasStartedLoading then
        m.StartRequest()
        m.hasStartedLoading = true

        if m.Listener <> invalid then
            m.Listener.OnDataLoaded(0, m.rowContent[0], 0, m.rowContent[0].Count(), true)
            if m.totalSize = 0 then m.Listener.Screen.SetFocusedListItem(0, 0)
        end if
    end if

    return true
End Function

Function chunkedGetLoadStatus(row) As Integer
    if m.rowContent[row].Count() > 0 then
        return 2
    else
        return 0
    end if
End Function

Function chunkedGetPendingRequestCount() As Integer
    if m.loadedSize >= m.totalSize then
        return 0
    else
        return 1
    end if
End Function

Sub chunkedRefreshData()
    if m.Listener <> invalid AND m.Listener.InitializeRows <> invalid then
        m.SetupRows()
        m.Listener.InitializeRows()
        m.StartRequest()
        m.Listener.OnDataLoaded(0, m.rowContent[0], 0, m.rowContent[0].Count(), true)
    end if
End Sub

Sub chunkedStartRequest()
    if m.loadedSize >= m.totalSize then return

    ' If we're loading the first row, try to just load the visible content.
    ' Otherwise, load a large chunk.
    if m.loadedSize = 0 then
        chunkSize = m.rowSize * 3
    else
        chunkSize = m.rowSize * 8
    end if

    request = CreateObject("roAssociativeArray")
    httpRequest = m.server.CreateRequest(m.sourceUrl, m.FilterOptions.GetUrl())
    httpRequest.AddHeader("X-Plex-Container-Start", tostr(m.loadedSize))
    httpRequest.AddHeader("X-Plex-Container-Size", tostr(chunkSize))
    request.offset = m.loadedSize

    ' Associate the request with our listener's screen ID, so that any pending
    ' requests are canceled when the screen is popped.
    m.ScreenID = m.Listener.ScreenID

    GetViewController().StartRequest(httpRequest, m, request)
End Sub

Sub chunkedOnUrlEvent(msg, requestContext)
    url = requestContext.Request.GetURL()

    if msg.GetResponseCode() <> 200 then
        Debug("Got a " + tostr(msg.GetResponseCode()) + " response from " + tostr(url) + " - " + tostr(msg.GetFailureReason()))
        return
    end if

    xml = CreateObject("roXMLElement")
    xml.Parse(msg.GetString())

    response = CreateObject("roAssociativeArray")
    response.xml = xml
    response.server = m.server
    response.sourceUrl = url
    container = createPlexContainerForXml(response)

    if response.xml@totalSize <> invalid then
        totalSize = strtoi(response.xml@totalSize)
    else
        totalSize = container.Count()
    end if

    if totalSize <> m.totalSize then
        Debug("Container's total size no longer matches expected value: " + tostr(totalSize) + " vs. " + tostr(m.totalSize))
    end if

    if totalSize > 0 then
        startItem = firstOf(response.xml@offset, msg.GetResponseHeaders()["X-Plex-Container-Start"], tostr(requestContext.offset)).toInt()
        countLoaded = container.Count()
        Debug("Received paginated response for index " + tostr(startItem) + " of list with length " + tostr(countLoaded))
        items = container.GetMetadata()
        firstRowNum% = (startItem / m.rowSize) + 1
        lastRowNum% = firstRowNum%
        for i = 0 to countLoaded - 1
            m.masterContent[startItem + i] = items[i]
            rowNum% = ((startItem + i) / m.rowSize) + 1
            rowIndex% = (startItem + i) MOD m.rowSize
            m.rowContent[rowNum%][rowIndex%] = items[i]
            lastRowNum% = rowNum%
        next

        m.loadedSize = m.masterContent.Count()
        m.StartRequest()

        if m.Listener <> invalid then
            for i = firstRowNum% to lastRowNum%
                m.Listener.OnDataLoaded(i, m.rowContent[i], 0, m.rowContent[i].Count(), true)
            next
        end if
    end if
End Sub
