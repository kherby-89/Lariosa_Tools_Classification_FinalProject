import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/analytics_models.dart';
import '../services/analytics_service.dart';

class AnalyticsScreen extends StatefulWidget {
  @override
  _AnalyticsScreenState createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  final AnalyticsService _analyticsService = AnalyticsService();
  late TabController _tabController;

  List<ToolUsageStats> _toolStats = [];
  List<DailyStats> _dailyStats = [];
  List<ConfidenceRange> _confidenceRanges = [];
  List<AnalyticsData> _recentPredictions = [];
  
  bool _isLoading = true;
  String _selectedTimeRange = '7 days';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadAnalyticsData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAnalyticsData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final days = _selectedTimeRange == '7 days' ? 7 : 
                   _selectedTimeRange == '30 days' ? 30 : 90;

      final results = await Future.wait([
        _analyticsService.getToolUsageStats(),
        _analyticsService.getDailyStats(days),
        _analyticsService.getConfidenceRangeStats(),
        _analyticsService.getAllPredictions(),
      ]);

      setState(() {
        _toolStats = results[0] as List<ToolUsageStats>;
        _dailyStats = results[1] as List<DailyStats>;
        _confidenceRanges = results[2] as List<ConfidenceRange>;
        _recentPredictions = (results[3] as List<AnalyticsData>).take(50).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _showErrorSnackBar('Failed to load analytics data: $e');
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _exportData(String format) async {
    try {
      await _analyticsService.shareAnalytics(format);
      _showSuccessSnackBar('Analytics data exported successfully!');
    } catch (e) {
      _showErrorSnackBar('Export failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('📊 Analytics Dashboard'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 4,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: [
            Tab(icon: Icon(Icons.pie_chart), text: 'Tools'),
            Tab(icon: Icon(Icons.timeline), text: 'Trends'),
            Tab(icon: Icon(Icons.assessment), text: 'Quality'),
            Tab(icon: Icon(Icons.list), text: 'Recent'),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.file_download),
            onSelected: _exportData,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'csv',
                child: Row(
                  children: [
                    Icon(Icons.table_chart, size: 20),
                    SizedBox(width: 8),
                    Text('Export as CSV'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'json',
                child: Row(
                  children: [
                    Icon(Icons.code, size: 20),
                    SizedBox(width: 8),
                    Text('Export as JSON'),
                  ],
                ),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.date_range),
            onSelected: (value) {
              setState(() {
                _selectedTimeRange = value;
              });
              _loadAnalyticsData();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: '7 days',
                child: Row(
                  children: [
                    Icon(Icons.calendar_view_week, size: 20),
                    SizedBox(width: 8),
                    Text('Last 7 days'),
                    if (_selectedTimeRange == '7 days') 
                      Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.check, size: 16, color: Colors.green),
                      ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: '30 days',
                child: Row(
                  children: [
                    Icon(Icons.calendar_view_month, size: 20),
                    SizedBox(width: 8),
                    Text('Last 30 days'),
                    if (_selectedTimeRange == '30 days') 
                      Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.check, size: 16, color: Colors.green),
                      ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: '90 days',
                child: Row(
                  children: [
                    Icon(Icons.calendar_month, size: 20),
                    SizedBox(width: 8),
                    Text('Last 90 days'),
                    if (_selectedTimeRange == '90 days') 
                      Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.check, size: 16, color: Colors.green),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.blue),
                  SizedBox(height: 16),
                  Text('Loading analytics data...'),
                ],
              ),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildToolUsageTab(),
                _buildTrendsTab(),
                _buildQualityTab(),
                _buildRecentTab(),
              ],
            ),
    );
  }

  Widget _buildToolUsageTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('🛠️ Tool Usage Distribution', 'Most frequently classified tools'),
          SizedBox(height: 16),
          if (_toolStats.isNotEmpty) ...[
            Container(
              height: 300,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 60,
                  sections: _buildPieChartSections(),
                ),
              ),
            ),
            SizedBox(height: 24),
            _buildToolStatsCards(),
          ] else
            _buildEmptyState('No tool usage data available'),
        ],
      ),
    );
  }

  Widget _buildTrendsTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('📈 Classification Trends', 'Daily usage patterns over $_selectedTimeRange'),
          SizedBox(height: 16),
          if (_dailyStats.isNotEmpty) ...[
            Container(
              height: 300,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          if (value.toInt() >= 0 && value.toInt() < _dailyStats.length) {
                            final date = _dailyStats.reversed.toList()[value.toInt()].date;
                            return Text(
                              DateFormat('MM/dd').format(date),
                              style: TextStyle(fontSize: 10),
                            );
                          }
                          return Text('');
                        },
                      ),
                    ),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _buildLineChartSpots(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 3,
                      dotData: FlDotData(show: true),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 24),
            _buildDailyStatsCards(),
          ] else
            _buildEmptyState('No trend data available'),
        ],
      ),
    );
  }

  Widget _buildQualityTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('🎯 Prediction Quality', 'Confidence distribution analysis'),
          SizedBox(height: 16),
          if (_confidenceRanges.isNotEmpty) ...[
            Container(
              height: 300,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: _confidenceRanges.map((r) => r.percentage).reduce((a, b) => a > b ? a : b) * 1.2,
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) => Text('${value.toInt()}%'),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          if (value.toInt() >= 0 && value.toInt() < _confidenceRanges.length) {
                            final range = _confidenceRanges[value.toInt()].range;
                            return Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                range.split(' ').first,
                                style: TextStyle(fontSize: 10),
                              ),
                            );
                          }
                          return Text('');
                        },
                      ),
                    ),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: _buildBarChartData(),
                ),
              ),
            ),
            SizedBox(height: 24),
            _buildConfidenceCards(),
          ] else
            _buildEmptyState('No quality data available'),
        ],
      ),
    );
  }

  Widget _buildRecentTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('⏱️ Recent Classifications', 'Last 50 predictions'),
          SizedBox(height: 16),
          if (_recentPredictions.isNotEmpty)
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: _recentPredictions.length,
              itemBuilder: (context, index) {
                final prediction = _recentPredictions[index];
                return _buildPredictionCard(prediction);
              },
            )
          else
            _buildEmptyState('No recent predictions'),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      height: 300,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.analytics, size: 64, color: Colors.grey[400]),
            SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            SizedBox(height: 8),
            Text(
              'Start classifying tools to see analytics',
              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  List<PieChartSectionData> _buildPieChartSections() {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.red,
      Colors.purple,
      Colors.teal,
      Colors.amber,
      Colors.indigo,
      Colors.pink,
      Colors.cyan,
    ];

    return _toolStats.asMap().entries.map((entry) {
      final index = entry.key;
      final tool = entry.value;
      final total = _toolStats.fold(0, (sum, t) => sum + t.count);
      final percentage = (tool.count / total) * 100;

      return PieChartSectionData(
        color: colors[index % colors.length],
        value: tool.count.toDouble(),
        title: '${percentage.toStringAsFixed(1)}%',
        radius: 80,
        titleStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      );
    }).toList();
  }

  Widget _buildToolStatsCards() {
    return Column(
      children: _toolStats.take(10).map((tool) {
        return Card(
          margin: EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.blue,
              child: Text(tool.toolName[0], style: TextStyle(color: Colors.white)),
            ),
            title: Text(tool.toolName),
            subtitle: Text('Avg. confidence: ${(tool.averageConfidence * 100).toStringAsFixed(1)}%'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${tool.count}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text('uses', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  List<FlSpot> _buildLineChartSpots() {
    final reversedStats = _dailyStats.reversed.toList();
    return reversedStats.asMap().entries.map((entry) {
      return FlSpot(entry.key.toDouble(), entry.value.totalClassifications.toDouble());
    }).toList();
  }

  Widget _buildDailyStatsCards() {
    final totalClassifications = _dailyStats.fold(0, (sum, day) => sum + day.totalClassifications);
    final avgConfidence = _dailyStats.isEmpty ? 0.0 : 
        _dailyStats.map((d) => d.averageConfidence).reduce((a, b) => a + b) / _dailyStats.length;

    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            'Total Classifications',
            totalClassifications.toString(),
            Icons.photo_camera,
            Colors.blue,
          ),
        ),
        SizedBox(width: 8),
        Expanded(
          child: _buildStatCard(
            'Average Confidence',
            '${(avgConfidence * 100).toStringAsFixed(1)}%',
            Icons.trending_up,
            Colors.green,
          ),
        ),
      ],
    );
  }

  List<BarChartGroupData> _buildBarChartData() {
    return _confidenceRanges.asMap().entries.map((entry) {
      final index = entry.key;
      final range = entry.value;

      return BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: range.percentage,
            color: Colors.blue,
            width: 20,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      );
    }).toList();
  }

  Widget _buildConfidenceCards() {
    return Column(
      children: _confidenceRanges.map((range) {
        return Card(
          margin: EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: _getConfidenceColor(range.range),
              child: Icon(Icons.assessment, color: Colors.white),
            ),
            title: Text(range.range),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${range.count}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text('(${range.percentage.toStringAsFixed(1)}%)', 
                     style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Color _getConfidenceColor(String range) {
    if (range.contains('Very High')) return Colors.green;
    if (range.contains('High')) return Colors.lightGreen;
    if (range.contains('Medium')) return Colors.orange;
    if (range.contains('Low')) return Colors.red;
    return Colors.grey;
  }

  Widget _buildPredictionCard(AnalyticsData prediction) {
    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue,
          child: Text(prediction.toolName[0], style: TextStyle(color: Colors.white)),
        ),
        title: Text(prediction.toolName),
        subtitle: Text(DateFormat('yyyy-MM-dd HH:mm').format(prediction.timestamp)),
        trailing: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _getConfidenceColor('${(prediction.confidence * 100).toInt()}'),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${(prediction.confidence * 100).toStringAsFixed(1)}%',
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text(title, style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}