import Foundation

public enum QuotaUsageMetric: String, Codable, CaseIterable, Sendable {
  case rate, allocation, exceeded, requests

  public var metricType: String {
    switch self {
    case .rate: "serviceruntime.googleapis.com/quota/rate/net_usage"
    case .allocation: "serviceruntime.googleapis.com/quota/allocation/usage"
    case .exceeded: "serviceruntime.googleapis.com/quota/exceeded"
    case .requests: "serviceruntime.googleapis.com/api/request_count"
    }
  }

  var resourceType: String { self == .requests ? "consumed_api" : "consumer_quota" }
}

/// Provider records remain lossless JSON: bucket dimensions, overrides, INT64s,
/// metric labels and distributions vary by service and metric type.
public struct QuotaPage: Equatable, Sendable, GatewayJSONRepresentable {
  public enum Kind: String, Codable, Sendable { case limits, usage, overrides }
  public enum DataStatus: String, Codable, Sendable { case reported, noData }
  public let kind: Kind
  public let records: [JSONValue]
  public let pagesFetched: Int
  public let nextPageToken: String?
  public let metric: QuotaUsageMetric?
  public let startTime: String?
  public let endTime: String?

  public var dataStatus: DataStatus { records.isEmpty ? .noData : .reported }

  public func gatewayJSONValue() -> JSONValue {
    var value: [String: JSONValue] = [
      "kind": .string(kind.rawValue), "records": .array(records),
      "dataStatus": .string(dataStatus.rawValue), "pagesFetched": .number(String(pagesFetched))
    ]
    if let nextPageToken { value["nextPageToken"] = .string(nextPageToken) }
    if let metric { value["metricType"] = .string(metric.metricType) }
    if let startTime { value["startTime"] = .string(startTime) }
    if let endTime { value["endTime"] = .string(endTime) }
    return .object(value)
  }
}

public struct QuotaPagination: Sendable {
  public var pageSize: Int
  public var pageToken: String?
  public var allPages: Bool

  public init(pageSize: Int = 100, pageToken: String? = nil, allPages: Bool = false) {
    self.pageSize = pageSize
    self.pageToken = pageToken
    self.allPages = allPages
  }
}

public struct QuotaUsageRequest: Sendable {
  public let project: String
  public let service: String
  public let metric: QuotaUsageMetric
  public let startTime: Date
  public let endTime: Date
  public let quotaMetric: String?
  public let pagination: QuotaPagination

  public init(
    project: String, service: String, metric: QuotaUsageMetric = .rate,
    startTime: Date, endTime: Date, quotaMetric: String? = nil, pagination: QuotaPagination = .init()
  ) {
    self.project = project; self.service = service; self.metric = metric
    self.startTime = startTime; self.endTime = endTime; self.quotaMetric = quotaMetric; self.pagination = pagination
  }
}
