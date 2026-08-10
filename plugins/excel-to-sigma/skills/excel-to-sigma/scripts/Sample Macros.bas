Attribute VB_Name = "FPAModel"
' ===== FP&A Monthly P&L — VBA behind the workbook =====
Option Explicit

' Auto-runs when the workbook opens
Private Sub Workbook_Open()
    Application.ScreenUpdating = False
    ThisWorkbook.RefreshAll
    Sheets("P&L").Activate
    Application.ScreenUpdating = True
End Sub

' "Refresh" button: pull latest GL + recalc
Sub RefreshActuals_Click()
    ThisWorkbook.RefreshAll
    Application.CalculateFull
    MsgBox "Actuals refreshed.", vbInformation
End Sub

' Rebuild the P&L actuals columns from the Data tab (SUMIFS in code)
Sub RebuildPnL()
    Dim ws As Worksheet, r As Long, lastRow As Long
    Set ws = Sheets("Data")
    lastRow = ws.Cells(ws.Rows.Count, "C").End(xlUp).Row
    Dim li As String, mo As String, amt As Double
    For r = 5 To lastRow
        li = ws.Cells(r, 3).Value
        mo = ws.Cells(r, 2).Value
        amt = ws.Cells(r, 6).Value
        ' accumulate into the P&L grid by line item / month
        Call PostToGrid(li, mo, amt)
    Next r
End Sub

' Apply a named scenario: write growth rates into the Assumptions cells
Sub ApplyScenario(scenarioName As String)
    Select Case scenarioName
        Case "Aggressive"
            Sheets("Assumptions").Range("B5").Value = 0.06  ' subscription growth
            Sheets("Assumptions").Range("B6").Value = 0.02
        Case "Conservative"
            Sheets("Assumptions").Range("B5").Value = 0.01
            Sheets("Assumptions").Range("B6").Value = 0.01
    End Select
    Application.CalculateFull
End Sub

' "Commit Forecast" button: freeze the current Jul-Dec forecast as values and
' append them to the Snapshot history tab
Sub CommitForecast_Click()
    Dim src As Range, dst As Worksheet, nextRow As Long
    Set dst = Sheets("Snapshots")
    nextRow = dst.Cells(dst.Rows.Count, 1).End(xlUp).Row + 1
    Set src = Sheets("P&L").Range("H7:M33")
    src.Copy
    dst.Cells(nextRow, 1).PasteSpecial Paste:=xlPasteValues
    dst.Cells(nextRow, 1).Value = Now
    Application.CutCopyMode = False
    MsgBox "Forecast committed to Snapshots.", vbInformation
End Sub

' "Save Scenario" button: append current assumptions to the Scenarios table
Sub SaveScenario_Click()
    Dim t As ListObject, newRow As ListRow
    Set t = Sheets("Scenarios").ListObjects("tblScenarios")
    Set newRow = t.ListRows.Add
    newRow.Range(1, 1).Value = InputBox("Scenario name?")
    newRow.Range(1, 2).Value = Sheets("Assumptions").Range("B5").Value
    newRow.Range(1, 3).Value = Sheets("Assumptions").Range("B6").Value
End Sub

' "Email to CFO" button: render the P&L to PDF and send via Outlook
Sub EmailReport_Click()
    Dim OutApp As Object, OutMail As Object, pdfPath As String
    pdfPath = Environ("TEMP") & "\PnL.pdf"
    Sheets("P&L").ExportAsFixedFormat Type:=xlTypePDF, Filename:=pdfPath
    Set OutApp = CreateObject("Outlook.Application")
    Set OutMail = OutApp.CreateItem(0)
    With OutMail
        .To = "cfo@example.com"
        .Subject = "Monthly P&L"
        .Body = "Latest P&L attached."
        .Attachments.Add pdfPath
        .Send
    End With
End Sub

' Navigation button
Sub GoToForecast_Click()
    Sheets("P&L").Activate
    Sheets("P&L").Range("H5").Select
End Sub

' Cosmetic formatting of the statement
Sub FormatStatement()
    With Sheets("P&L").Range("A6:N33")
        .Font.Name = "Calibri"
        .Columns.AutoFit
    End With
    Sheets("P&L").Range("A9,A15,A24").Font.Bold = True
End Sub

' Goal-seek: solve the subscription growth needed to hit a Net Income target
Sub SolveForTarget()
    Sheets("P&L").Range("N33").GoalSeek Goal:=2000000, _
        ChangingCell:=Sheets("Assumptions").Range("B5")
End Sub

' Opaque bespoke allocation — multi-step imperative logic, no clean declarative equivalent
Sub AllocateOverheadByHeadcount()
    Dim depts As Variant, hc As Variant, i As Integer, total As Double
    depts = Array("Eng", "Sales", "G&A", "Support")
    hc = Sheets("Headcount").Range("B2:B5").Value
    For i = 1 To 4
        total = total + hc(i, 1)
    Next i
    For i = 1 To 4
        Sheets("Alloc").Cells(i + 1, 2).Value = _
            (hc(i, 1) / total) * Sheets("Assumptions").Range("B12").Value * _
            (1 + 0.5 * Sin(i)) ' bespoke smoothing factor
    Next i
End Sub
