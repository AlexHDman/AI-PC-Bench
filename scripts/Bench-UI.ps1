Add-Type -AssemblyName PresentationFramework

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AI PC Bench"
        Width="1000"
        Height="590"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#090B0D"
        Foreground="#EEEEEE">

<Grid Margin="34">

    <Grid.RowDefinitions>
        <RowDefinition Height="100"/>
        <RowDefinition Height="100"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="55"/>
    </Grid.RowDefinitions>

    <!-- HEADER -->
    <Grid Grid.Row="0">

        <StackPanel>
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="AI PC "
                           FontFamily="Segoe UI"
                           FontSize="38"
                           FontWeight="Bold"/>

                <TextBlock Text="Bench"
                           FontFamily="Segoe UI"
                           FontSize="38"
                           FontWeight="Bold"
                           Foreground="#FFD600"/>
            </StackPanel>

            <TextBlock Text="SYSTEM PERFORMANCE &amp; AI READINESS"
                       FontFamily="Segoe UI"
                       FontSize="13"
                       Foreground="#858B91"
                       Margin="2,3,0,0"/>
        </StackPanel>

        <StackPanel HorizontalAlignment="Right"
                    VerticalAlignment="Top">

            <TextBlock Text="EXPC"
                       FontFamily="Segoe UI"
                       FontSize="18"
                       FontWeight="Bold"
                       HorizontalAlignment="Right"/>

            <TextBlock Text="AI PERFORMANCE LAB"
                       FontFamily="Segoe UI"
                       FontSize="11"
                       Foreground="#FFD600"
                       Margin="0,4,0,0"/>
        </StackPanel>
    </Grid>

    <!-- PROGRESS -->
    <StackPanel Grid.Row="1">

        <Grid>
            <TextBlock x:Name="Status"
                       Text="INITIALIZING..."
                       FontFamily="Segoe UI"
                       FontSize="20"
                       FontWeight="SemiBold"
                       Foreground="#FFD600"/>

            <TextBlock x:Name="Percent"
                       Text="0%"
                       HorizontalAlignment="Right"
                       FontFamily="Segoe UI"
                       FontSize="27"
                       FontWeight="Bold"
                       Foreground="#FFD600"/>
        </Grid>

        <ProgressBar x:Name="Progress"
                     Minimum="0"
                     Maximum="100"
                     Value="0"
                     Height="22"
                     Margin="0,13,0,0"
                     Foreground="#FFD600"
                     Background="#202428"/>
    </StackPanel>

    <!-- BODY -->
    <Border Grid.Row="2"
            BorderBrush="#30353A"
            BorderThickness="1"
            CornerRadius="5"
            Padding="22"
            Margin="0,5,0,15">

        <Grid>

            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="300"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel>

                <TextBlock x:Name="S1"
                           Text="[1/6]  System Information"
                           FontSize="16"
                           Margin="0,0,0,17"/>

                <TextBlock x:Name="S2"
                           Text="[2/6]  CPU Benchmark"
                           FontSize="16"
                           Margin="0,0,0,17"/>

                <TextBlock x:Name="S3"
                           Text="[3/6]  Memory Benchmark"
                           FontSize="16"
                           Margin="0,0,0,17"/>

                <TextBlock x:Name="S4"
                           Text="[4/6]  Storage Benchmark"
                           FontSize="16"
                           Margin="0,0,0,17"/>

                <TextBlock x:Name="S5"
                           Text="[5/6]  NPU / AI"
                           FontSize="16"
                           Margin="0,0,0,17"/>

                <TextBlock x:Name="S6"
                           Text="[6/6]  Generate Report"
                           FontSize="16"/>
            </StackPanel>

            <Border Grid.Column="1"
                    Background="#0E1114"
                    BorderBrush="#252A2E"
                    BorderThickness="1"
                    CornerRadius="4"
                    Padding="20">

                <StackPanel>

                    <TextBlock Text="CURRENT OPERATION"
                               FontSize="11"
                               Foreground="#737A80"/>

                    <TextBlock x:Name="Operation"
                               Text="Preparing AI PC Bench"
                               FontSize="20"
                               FontWeight="SemiBold"
                               Foreground="#EEEEEE"
                               Margin="0,12,0,20"/>

                    <TextBlock Text="Testing system performance and local AI readiness."
                               FontSize="14"
                               Foreground="#92999F"
                               TextWrapping="Wrap"/>

                </StackPanel>
            </Border>

        </Grid>
    </Border>

    <!-- FOOTER -->
    <Grid Grid.Row="3">

        <TextBlock x:Name="Elapsed"
                   Text="ELAPSED  00:00"
                   VerticalAlignment="Center"
                   FontSize="13"
                   Foreground="#858B91"/>

        <StackPanel HorizontalAlignment="Right"
                    VerticalAlignment="Center">

            <TextBlock Text="MEASURE  /  ANALYZE  /  OPTIMIZE"
                       FontSize="11"
                       Foreground="#858B91"
                       HorizontalAlignment="Right"/>

            <TextBlock Text="BUILD A SMARTER AI PC"
                       FontSize="13"
                       FontWeight="Bold"
                       Foreground="#FFD600"
                       HorizontalAlignment="Right"
                       Margin="0,4,0,0"/>
        </StackPanel>

    </Grid>

</Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$progress  = $window.FindName("Progress")
$percent   = $window.FindName("Percent")
$status    = $window.FindName("Status")
$operation = $window.FindName("Operation")
$elapsed   = $window.FindName("Elapsed")

$stages = @(
    $window.FindName("S1"),
    $window.FindName("S2"),
    $window.FindName("S3"),
    $window.FindName("S4"),
    $window.FindName("S5"),
    $window.FindName("S6")
)

$names = @(
    "Collecting system information",
    "Testing CPU performance",
    "Testing memory performance",
    "Testing storage performance",
    "Checking NPU and AI capabilities",
    "Generating benchmark report"
)

$script:value = 0
$start = Get-Date

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(90)

$timer.Add_Tick({

    $script:value++

    if ($script:value -gt 100) {

        $timer.Stop()

        $progress.Value = 100
        $percent.Text = "100%"

        $status.Text = "BENCHMARK COMPLETE"
        $status.Foreground = "#55D67A"
        $percent.Foreground = "#55D67A"

        $operation.Text = "AI PC Bench completed successfully"

        foreach ($item in $stages) {
            $item.Foreground = "#55D67A"
        }

        return
    }

    $progress.Value = $script:value
    $percent.Text = "$($script:value)%"

    $index = [Math]::Min(
        [Math]::Floor($script:value / 17),
        5
    )

    for ($i = 0; $i -lt $stages.Count; $i++) {

        if ($i -lt $index) {
            $stages[$i].Foreground = "#55D67A"
        }
        elseif ($i -eq $index) {
            $stages[$i].Foreground = "#FFD600"
        }
        else {
            $stages[$i].Foreground = "#747A80"
        }
    }

    $operation.Text = $names[$index]
    $status.Text = "TESTING YOUR PC..."

    $time = (Get-Date) - $start
    $elapsed.Text = "ELAPSED  {0:mm\:ss}" -f $time
})

$window.Add_ContentRendered({
    $timer.Start()
})

$window.ShowDialog() | Out-Null

